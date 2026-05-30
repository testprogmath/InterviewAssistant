//
//  InterviewCoordinator.swift
//  InterviewAssistant
//
//  The top-level orchestrator for an interview. Owns the lifecycle:
//
//      start  →  recording → stop → transcribing → ready
//
//  Reads / writes everything through SessionStore, so all artefacts for an
//  interview live in one tidy folder on disk.
//
//  The UI talks only to this object — it does not need to know about
//  AudioCaptureService, TranscriptionService, or SpeakerMergeService.
//

import Foundation
import OSLog
import Combine
import AVFoundation

@MainActor
final class InterviewCoordinator: ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case transcribing
        case ready                 // session exists and has a transcript
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSession: Session?
    @Published private(set) var elapsedSeconds: Int = 0

    /// Set while an LLM analysis is in flight (Summary / SWOT / Recommendation / FollowUps).
    /// `nil` when idle.
    @Published private(set) var ongoingAnalysis: String?
    @Published private(set) var lastAnalysisError: String?

    /// All sessions persisted on disk, newest first. Refreshed on demand.
    @Published private(set) var allSessions: [Session] = []

    /// Fraction of the current transcription job done (0…1) or nil.
    @Published private(set) var transcriptionFraction: Double?

    /// Latest text snippet from Whisper — proves the pipeline is alive.
    @Published private(set) var transcriptionPreview: String = ""

    // MARK: - Dependencies

    private let store:         SessionStore
    private let capture:       AudioCaptureService
    private let transcription: TranscriptionService
    private let merger:        SpeakerMergeService
    private let providerSettings: ProviderSettings
    private let log = Logger(subsystem: "com.anna.interview", category: "Coordinator")

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    init(
        store:            SessionStore,
        capture:          AudioCaptureService,
        transcription:    TranscriptionService,
        providerSettings: ProviderSettings,
        merger:           SpeakerMergeService = SpeakerMergeService()
    ) {
        self.store            = store
        self.capture          = capture
        self.transcription    = transcription
        self.merger           = merger
        self.providerSettings = providerSettings

        // Mirror the capture service's elapsed counter so the UI only has
        // to bind to this coordinator.
        capture.$elapsedSeconds
            .receive(on: DispatchQueue.main)
            .assign(to: \.elapsedSeconds, on: self)
            .store(in: &cancellables)

        // Same for live transcription progress.
        transcription.$progressFraction
            .receive(on: DispatchQueue.main)
            .assign(to: \.transcriptionFraction, on: self)
            .store(in: &cancellables)
        transcription.$progressPreview
            .receive(on: DispatchQueue.main)
            .assign(to: \.transcriptionPreview, on: self)
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Start a new interview. Creates a fresh Session on disk and begins
    /// recording into its audio/ subfolder.
    func startInterview(candidateName: String? = nil, position: String? = nil) async {
        guard canStart else { return }
        state = .preparing

        do {
            let metadata = InterviewMetadata(
                candidateName: candidateName,
                position:      position,
                recordedAt:    Date(),
                duration:      0
            )
            let session = try store.create(metadata: metadata)
            currentSession = session

            await capture.start(
                interviewerURL: store.interviewerAudioURL(for: session.id),
                candidateURL:   store.candidateAudioURL(for: session.id)
            )

            if case .error(let m) = capture.state {
                state = .failed(m)
                return
            }

            state = .recording
            log.info("Interview \(session.id.uuidString) started")
        } catch {
            log.error("Could not start interview: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop recording and automatically run the full transcribe + merge +
    /// save pipeline. The UI doesn't have to chain anything itself.
    func stopAndProcess() async {
        guard state == .recording else { return }
        state = .stopping
        log.info("Stopping recording…")

        guard let recording = await capture.stop(),
              var session = currentSession else {
            state = .failed("Не удалось остановить запись")
            return
        }

        // Update duration on the session and persist.
        session.metadata = InterviewMetadata(
            candidateName: session.metadata.candidateName,
            position:      session.metadata.position,
            recordedAt:    session.metadata.recordedAt,
            duration:      recording.duration
        )
        currentSession = session
        try? store.save(session)

        await runTranscription(for: session, recording: recording)
    }

    /// Re-run transcription on an already recorded session (e.g. after
    /// changing the Whisper model or fixing audio). Useful for the
    /// "Перетранскрибировать" button.
    func retranscribe() async {
        guard let session = currentSession else { return }
        let interviewerURL = store.interviewerAudioURL(for: session.id)
        let candidateURL   = store.candidateAudioURL(for: session.id)

        let recording = AudioCaptureService.Recording(
            interviewerURL: interviewerURL,
            candidateURL:   candidateURL,
            startedAt:      session.metadata.recordedAt,
            duration:       session.metadata.duration
        )
        await runTranscription(for: session, recording: recording)
    }

    /// Reset to a clean state, forgetting the current session reference.
    /// Files on disk are NOT removed.
    func reset() {
        state = .idle
        currentSession = nil
        elapsedSeconds = 0
    }

    // MARK: - Internal

    private func runTranscription(
        for session: Session,
        recording: AudioCaptureService.Recording
    ) async {
        state = .transcribing
        log.info("Transcribing session \(session.id.uuidString)…")

        do {
            // Imported sessions only have a candidate track. Skip the
            // interviewer side gracefully if the file isn't on disk.
            let fm = FileManager.default

            var interviewerSegments: [TranscriptSegment] = []
            if fm.fileExists(atPath: recording.interviewerURL.path) {
                interviewerSegments = try await transcription.transcribe(
                    audioURL: recording.interviewerURL,
                    as: .interviewer
                )
            } else {
                log.info("No interviewer track — single-track session")
            }

            let candidateSegments = try await transcription.transcribe(
                audioURL: recording.candidateURL,
                as: .candidate
            )

            let merged = merger.merge(
                interviewer: interviewerSegments,
                candidate:   candidateSegments
            )

            let modelInfo = transcription.modelInfo
                ?? TranscriptionModelInfo(
                    provider: "whisperkit",
                    model:    "unknown",
                    version:  "unknown"
                )

            let transcript = Transcript(
                segments:         merged,
                language:         "ru",
                durationSeconds:  recording.duration,
                modelInfo:        modelInfo
            )

            var updated = session
            updated.transcript = transcript

            try store.save(updated)
            currentSession = updated
            state = .ready
            refreshSessions()

            log.info("Session ready: \(merged.count) segments saved")
        } catch {
            log.error("Transcription failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    private var canStart: Bool {
        switch state {
        case .idle, .ready, .failed: return true
        default:                     return false
        }
    }

    // MARK: - LLM analysis

    enum AnalysisKind: String {
        case summary       = "Саммари"
        case swot          = "SWOT"
        case recommendation = "Рекомендация"
        case followUps     = "Уточняющие вопросы"
    }

    /// Run one of the structured analyses and persist the result onto the
    /// current session.
    func runAnalysis(_ kind: AnalysisKind) async {
        guard var session = currentSession,
              let transcript = session.transcript
        else {
            lastAnalysisError = "Сначала запиши и расшифруй интервью"
            return
        }
        guard let provider = providerSettings.currentProvider() else {
            lastAnalysisError = "Сначала укажи провайдер LLM и API-ключ в Настройках"
            return
        }

        ongoingAnalysis = kind.rawValue
        lastAnalysisError = nil
        log.info("Running analysis: \(kind.rawValue) via \(provider.descriptor.id)")

        do {
            switch kind {
            case .summary:
                session.summary = try await provider.generateSummary(
                    transcript: transcript, metadata: session.metadata
                )
            case .swot:
                session.swot = try await provider.generateSWOT(
                    transcript: transcript, metadata: session.metadata
                )
            case .recommendation:
                session.recommendation = try await provider.generateRecommendation(
                    transcript: transcript, metadata: session.metadata
                )
            case .followUps:
                session.followUpQuestions = try await provider.generateFollowUpQuestions(
                    transcript: transcript, metadata: session.metadata
                )
            }
            try store.save(session)
            currentSession = session
            log.info("Analysis '\(kind.rawValue)' saved")
        } catch {
            log.error("Analysis '\(kind.rawValue)' failed: \(error.localizedDescription)")
            lastAnalysisError = "\(kind.rawValue): \(error.localizedDescription)"
        }

        ongoingAnalysis = nil
    }

    func clearAnalysisError() {
        lastAnalysisError = nil
    }

    // MARK: - History / library

    /// Reload the list of all persisted sessions.
    func refreshSessions() {
        do {
            allSessions = try store.loadAll()
        } catch {
            log.error("Could not load sessions: \(error.localizedDescription)")
        }
    }

    /// Switch the UI to viewing a previously recorded session.
    func loadSession(_ id: UUID) {
        do {
            let session = try store.load(id: id)
            currentSession = session
            state = session.transcript != nil ? .ready : .idle
            elapsedSeconds = Int(session.metadata.duration)
            lastAnalysisError = nil
        } catch {
            log.error("Could not load session \(id.uuidString): \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Permanently delete a session and its files.
    func deleteSession(_ id: UUID) {
        do {
            try store.delete(id: id)
            if currentSession?.id == id {
                reset()
            }
            refreshSessions()
        } catch {
            log.error("Could not delete session \(id.uuidString): \(error.localizedDescription)")
        }
    }

    // MARK: - File import

    /// Import an audio or video file as a single-track interview. The
    /// imported audio is treated as the candidate channel; the interviewer
    /// track is left empty. Speaker separation isn't possible from one
    /// mixed stream — the user is expected to know this.
    func importFile(
        from sourceURL: URL,
        candidateName: String? = nil,
        position: String? = nil
    ) async {
        guard canStart else { return }
        state = .preparing
        log.info("Importing \(sourceURL.lastPathComponent)…")

        do {
            // Probe duration up-front so the session metadata is honest.
            let asset = AVURLAsset(url: sourceURL)
            let duration = try await asset.load(.duration).seconds.isFinite
                ? try await asset.load(.duration).seconds
                : 0

            let metadata = InterviewMetadata(
                candidateName: candidateName,
                position:      position,
                recordedAt:    Date(),
                duration:      duration
            )
            var session = try store.create(metadata: metadata)
            currentSession = session

            // Make sure the audio dir exists (SessionStore.create already
            // does this, belt-and-braces).
            try FileManager.default.createDirectory(
                at: store.audioDirectory(for: session.id),
                withIntermediateDirectories: true
            )

            // Convert to .m4a so the file is small and uniform on disk
            // regardless of what the user dropped in.
            let candidateURL = store.audioDirectory(for: session.id)
                .appendingPathComponent("candidate.m4a")
            try await extractAudio(from: sourceURL, to: candidateURL)

            state = .transcribing

            let candidateSegments = try await transcription.transcribe(
                audioURL: candidateURL,
                as: .candidate
            )

            let modelInfo = transcription.modelInfo
                ?? TranscriptionModelInfo(
                    provider: "whisperkit",
                    model:    "unknown",
                    version:  "unknown"
                )

            session.transcript = Transcript(
                segments:         candidateSegments,
                language:         "ru",
                durationSeconds:  duration,
                modelInfo:        modelInfo
            )
            try store.save(session)
            currentSession = session
            state = .ready
            refreshSessions()
            log.info("Import complete: \(candidateSegments.count) segments")
        } catch {
            log.error("Import failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Extract the audio track of any media file (audio or video) into an
    /// AAC-encoded .m4a. AVAssetExportSession handles every container
    /// AVFoundation knows about — mp3, m4a, mp4, mov, wav, flac, etc.
    private func extractAudio(from source: URL, to target: URL) async throws {
        try? FileManager.default.removeItem(at: target)
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(
                domain: "Import", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать экспортёр для этого формата"]
            )
        }
        export.outputURL = target
        export.outputFileType = .m4a
        export.audioTimePitchAlgorithm = .spectral

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    cont.resume()
                default:
                    let err = export.error
                        ?? NSError(domain: "Import", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Экспорт аудио прерван"])
                    cont.resume(throwing: err)
                }
            }
        }
    }
}
