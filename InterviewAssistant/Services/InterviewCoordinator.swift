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
import AppKit

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

    /// ID of the session whose transcription is running RIGHT NOW.
    /// `nil` when nothing is transcribing. There can only be one active
    /// transcription at a time (WhisperKit is single-tenant); everything
    /// else queues in `pendingTranscriptions`.
    @Published private(set) var transcribingSessionID: UUID?

    /// IDs of sessions waiting in the background transcription queue.
    @Published private(set) var queuedTranscriptionIDs: [UUID] = []

    /// Fraction of the current transcription job done (0…1) or nil.
    @Published private(set) var transcriptionFraction: Double?

    /// Latest text snippet from Whisper — proves the pipeline is alive.
    @Published private(set) var transcriptionPreview: String = ""

    /// Mirror of `TranscriptionService.state`, so the UI can show
    /// "Loading model…" vs "Transcribing…" separately.
    @Published private(set) var transcriptionServiceState: TranscriptionService.State = .idle

    /// Seconds since the model started loading (only meaningful while
    /// `transcriptionServiceState == .loadingModel`).
    @Published private(set) var modelLoadingSeconds: Int = 0
    private var modelLoadingTimer: Timer?
    private var modelLoadingStartedAt: Date?

    // ── Streaming chat / custom analysis ──────────────────────────────────

    /// Conversation with the model about the currently loaded interview.
    /// Reset whenever `currentSession` changes.
    @Published var chatHistory: [ChatMessage] = []

    /// Live text being streamed back from the model for chat. Empty when
    /// idle.
    @Published private(set) var streamingChatReply: String = ""

    /// Live text being streamed for a custom analysis.
    @Published private(set) var streamingCustomReply: String = ""

    /// Title of the in-flight custom analysis (used for the saved artefact).
    @Published private(set) var streamingCustomTitle: String = ""

    /// Whether *some* streaming operation is in flight — disables the
    /// "Send" / "Run" buttons in UI.
    @Published private(set) var isStreaming: Bool = false

    private var streamingTask: Task<Void, Never>?

    /// Internal queue of background transcription jobs.
    private struct PendingTranscription {
        let sessionID:      UUID
        let interviewerURL: URL
        let candidateURL:   URL
        let duration:       TimeInterval
        let singleTrack:    Bool      // true for imported files
    }
    private var pendingTranscriptions: [PendingTranscription] = []

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
        transcription.$state
            .receive(on: DispatchQueue.main)
            .assign(to: \.transcriptionServiceState, on: self)
            .store(in: &cancellables)

        transcription.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleTranscriptionState(state)
            }
            .store(in: &cancellables)

        // Quietly start loading the Whisper model in the background so the
        // first real recording doesn't wait for it.
        Task { [weak self] in
            try? await self?.transcription.prewarm()
        }
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

    /// Stop recording and queue transcription for background processing.
    /// The user is freed up to start a new recording immediately — the
    /// transcription continues silently and the sidebar shows a spinner
    /// on the still-processing session.
    func stopAndProcess() async {
        guard state == .recording else { return }
        state = .stopping
        log.info("Stopping recording…")

        guard let recording = await capture.stop(),
              var session = currentSession else {
            state = .failed("Не удалось остановить запись")
            return
        }

        // Save metadata immediately so the sidebar row is "real".
        session.metadata = InterviewMetadata(
            candidateName: session.metadata.candidateName,
            position:      session.metadata.position,
            recordedAt:    session.metadata.recordedAt,
            duration:      recording.duration
        )
        currentSession = session
        try? store.save(session)
        refreshSessions()

        // The recording flow is done — let the user start another interview.
        state = .ready

        // Spin off the slow part in the background.
        enqueueBackgroundTranscription(
            sessionID:      session.id,
            interviewerURL: recording.interviewerURL,
            candidateURL:   recording.candidateURL,
            duration:       recording.duration,
            singleTrack:    false
        )
    }

    /// Re-run transcription on an already recorded session (e.g. after
    /// changing the Whisper model or fixing audio). Useful for the
    /// "Перетранскрибировать" button. Runs in background like a fresh
    /// recording would.
    func retranscribe() {
        guard let session = currentSession else { return }
        let fm = FileManager.default
        let interviewerURL = store.interviewerAudioURL(for: session.id)
        let candidateURL   = store.candidateAudioURL(for: session.id)
        let singleTrack    = !fm.fileExists(atPath: interviewerURL.path)

        enqueueBackgroundTranscription(
            sessionID:      session.id,
            interviewerURL: interviewerURL,
            candidateURL:   candidateURL,
            duration:       session.metadata.duration,
            singleTrack:    singleTrack
        )
    }

    /// Reset to a clean state, forgetting the current session reference.
    /// Files on disk are NOT removed.
    func reset() {
        state = .idle
        currentSession = nil
        elapsedSeconds = 0
    }

    /// Update metadata fields on the current session and persist.
    func updateCurrentMetadata(candidateName: String?, position: String?) {
        guard var session = currentSession else { return }
        session.metadata.candidateName = candidateName?.isEmpty == true ? nil : candidateName
        session.metadata.position      = position?.isEmpty      == true ? nil : position
        try? store.save(session)
        currentSession = session
        refreshSessions()
    }

    // MARK: - Internal

    // MARK: - Background transcription queue

    /// Add a transcription to the queue. If nothing is running, kick off
    /// the worker; otherwise the job will be picked up automatically when
    /// the current one finishes.
    private func enqueueBackgroundTranscription(
        sessionID: UUID,
        interviewerURL: URL,
        candidateURL: URL,
        duration: TimeInterval,
        singleTrack: Bool
    ) {
        let job = PendingTranscription(
            sessionID:      sessionID,
            interviewerURL: interviewerURL,
            candidateURL:   candidateURL,
            duration:       duration,
            singleTrack:    singleTrack
        )
        pendingTranscriptions.append(job)
        queuedTranscriptionIDs.append(sessionID)
        log.info("Queued transcription for \(sessionID.uuidString); queue depth \(self.pendingTranscriptions.count)")

        if transcribingSessionID == nil {
            Task { @MainActor [weak self] in
                await self?.drainTranscriptionQueue()
            }
        }
    }

    /// Pull jobs off the queue one at a time and process them. WhisperKit
    /// is single-tenant, so we never want two of these running in parallel.
    private func drainTranscriptionQueue() async {
        while !pendingTranscriptions.isEmpty {
            let job = pendingTranscriptions.removeFirst()
            queuedTranscriptionIDs.removeAll { $0 == job.sessionID }
            transcribingSessionID = job.sessionID
            await runBackgroundJob(job)
            transcribingSessionID = nil
        }
    }

    /// Run a single job and persist the result. If the user is currently
    /// viewing this session, update the on-screen copy too.
    private func runBackgroundJob(_ job: PendingTranscription) async {
        log.info("Background transcription started: \(job.sessionID.uuidString)")
        let fm = FileManager.default

        do {
            // Imported single-track sessions only have the candidate file.
            var interviewerSegments: [TranscriptSegment] = []
            if !job.singleTrack && fm.fileExists(atPath: job.interviewerURL.path) {
                interviewerSegments = try await transcription.transcribe(
                    audioURL: job.interviewerURL, as: .interviewer
                )
            }
            let candidateSegments = try await transcription.transcribe(
                audioURL: job.candidateURL, as: .candidate
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
                segments:        merged,
                language:        "ru",
                durationSeconds: job.duration,
                modelInfo:       modelInfo
            )

            // Re-load the session in case other state has changed.
            var updated = (try? store.load(id: job.sessionID))
                ?? Session(id: job.sessionID, metadata: InterviewMetadata(duration: job.duration))
            updated.transcript = transcript
            try store.save(updated)

            // If the user is currently viewing this session, refresh the
            // detail view too.
            if currentSession?.id == updated.id {
                currentSession = updated
                state = .ready
            }
            refreshSessions()
            log.info("Background transcription done: \(merged.count) segments")
        } catch {
            log.error("Background transcription failed: \(error.localizedDescription)")
            if currentSession?.id == job.sessionID {
                lastAnalysisError = "Транскрипция: \(error.localizedDescription)"
            }
        }
    }

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

    /// Look for sessions that have audio on disk but no transcript yet
    /// (typically because the previous run of the app was killed mid-job)
    /// and queue them for background transcription.
    ///
    /// Safe to call multiple times — a session that's already being
    /// transcribed or queued won't be enqueued again.
    func resumeIncompleteTranscriptions() {
        refreshSessions()
        let fm = FileManager.default

        for session in allSessions where session.transcript == nil {
            // Skip if already in flight or queued
            if transcribingSessionID == session.id { continue }
            if queuedTranscriptionIDs.contains(session.id) { continue }

            let candidateURL = store.candidateAudioURL(for: session.id)
            guard fm.fileExists(atPath: candidateURL.path) else { continue }

            let interviewerURL = store.interviewerAudioURL(for: session.id)
            let singleTrack    = !fm.fileExists(atPath: interviewerURL.path)

            log.info("Resuming interrupted transcription for \(session.id.uuidString)")
            enqueueBackgroundTranscription(
                sessionID:      session.id,
                interviewerURL: interviewerURL,
                candidateURL:   candidateURL,
                duration:       session.metadata.duration,
                singleTrack:    singleTrack
            )
        }
    }

    /// Switch the UI to viewing a previously recorded session.
    func loadSession(_ id: UUID) {
        cancelStreaming()
        chatHistory = []
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

    /// Drive the model-loading timer based on TranscriptionService state.
    private func handleTranscriptionState(_ state: TranscriptionService.State) {
        if case .loadingModel = state {
            if modelLoadingStartedAt == nil {
                modelLoadingStartedAt = Date()
                modelLoadingSeconds = 0
                modelLoadingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let started = self.modelLoadingStartedAt else { return }
                        self.modelLoadingSeconds = Int(Date().timeIntervalSince(started))
                    }
                }
            }
        } else {
            modelLoadingTimer?.invalidate()
            modelLoadingTimer = nil
            modelLoadingStartedAt = nil
            modelLoadingSeconds = 0
        }
    }

    /// Open the session's folder in Finder.
    func revealInFinder(_ id: UUID) {
        let dir = store.sessionDirectory(for: id)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
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
            let session = try store.create(metadata: metadata)
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

            // Audio is in place — release the UI and let transcription
            // run in the background, same as a recorded session.
            state = .ready
            refreshSessions()

            enqueueBackgroundTranscription(
                sessionID:      session.id,
                interviewerURL: store.interviewerAudioURL(for: session.id), // won't exist
                candidateURL:   candidateURL,
                duration:       duration,
                singleTrack:    true
            )
            log.info("Imported \(sourceURL.lastPathComponent); transcription queued")
        } catch {
            log.error("Import failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Streaming: chat with the model

    /// Send the user's message to the model and stream the reply token by
    /// token into `streamingChatReply`. When the stream finishes, the full
    /// exchange is committed to `chatHistory`.
    func sendChatMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let session = currentSession,
              let transcript = session.transcript,
              let provider = providerSettings.currentProvider()
        else {
            lastAnalysisError = "Сначала запиши и расшифруй интервью + настрой LLM-провайдера"
            return
        }

        let userMessage = ChatMessage(role: .user, content: trimmed)
        chatHistory.append(userMessage)
        streamingChatReply = ""
        isStreaming = true

        // Keep only the last few turns to avoid blowing past the model's
        // context window — system prompt + transcript already eat a lot.
        let trimmedHistory = Self.trimChatHistory(chatHistory)

        streamingTask = Task { [history = trimmedHistory, weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = provider.streamChat(
                    messages:   history,
                    transcript: transcript,
                    metadata:   session.metadata
                )
                for try await chunk in stream {
                    accumulated += chunk
                    self.streamingChatReply = accumulated
                }
                if !accumulated.isEmpty {
                    self.chatHistory.append(ChatMessage(role: .assistant, content: accumulated))
                }
            } catch is CancellationError {
                // Quietly drop
            } catch {
                self.lastAnalysisError = "Чат: \(error.localizedDescription)"
            }
            self.streamingChatReply = ""
            self.isStreaming = false
            self.streamingTask = nil
        }
    }

    /// Drop the running chat or custom-analysis stream.
    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
        streamingChatReply = ""
        streamingCustomReply = ""
    }

    /// Reset the chat panel (forget all prior messages).
    func resetChat() {
        cancelStreaming()
        chatHistory = []
    }

    /// Drop oldest chat turns until the remaining text fits a soft budget.
    /// Rough heuristic: 4 chars ≈ 1 token, target ≤ 4000 tokens of chat
    /// history (leaves headroom for system prompt + transcript + reply).
    private static func trimChatHistory(_ history: [ChatMessage]) -> [ChatMessage] {
        let budgetChars = 16_000
        var total = 0
        var kept: [ChatMessage] = []
        for msg in history.reversed() {
            total += msg.content.count
            if total > budgetChars && !kept.isEmpty { break }
            kept.append(msg)
        }
        return kept.reversed()
    }

    // MARK: - Streaming: custom analysis (free-form prompt)

    /// Run an arbitrary prompt against the transcript and stream the
    /// markdown answer into `streamingCustomReply`. When complete, the
    /// answer is persisted as a `CustomAnalysis` on the session.
    func runCustomAnalysis(title: String, prompt: String) {
        let promptT = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleT  = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptT.isEmpty,
              var session = currentSession,
              let transcript = session.transcript,
              let provider = providerSettings.currentProvider()
        else {
            lastAnalysisError = "Введи промпт и убедись, что интервью расшифровано и LLM-провайдер настроен"
            return
        }

        let resolvedTitle = titleT.isEmpty ? "Свой анализ" : titleT

        streamingCustomTitle = resolvedTitle
        streamingCustomReply = ""
        isStreaming = true

        streamingTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = provider.streamCustomAnalysis(
                    title:      resolvedTitle,
                    prompt:     promptT,
                    transcript: transcript,
                    metadata:   session.metadata
                )
                for try await chunk in stream {
                    accumulated += chunk
                    self.streamingCustomReply = accumulated
                }
                if !accumulated.isEmpty {
                    let analysis = CustomAnalysis(
                        title:    resolvedTitle,
                        prompt:   promptT,
                        result:   accumulated,
                        provider: provider.providerInfo
                    )
                    session.customAnalyses.append(analysis)
                    try? self.store.save(session)
                    self.currentSession = session
                    self.refreshSessions()
                }
            } catch is CancellationError {
                // Quietly drop
            } catch {
                self.lastAnalysisError = "Свой анализ: \(error.localizedDescription)"
            }
            self.streamingCustomReply = ""
            self.streamingCustomTitle = ""
            self.isStreaming = false
            self.streamingTask = nil
        }
    }

    /// Apply a user-defined notes template to the current session. The
    /// underlying mechanism is the same streaming custom-analysis flow —
    /// we just use a different prompt and the template's name as title.
    func applyNotesTemplate(_ template: NotesTemplate) {
        guard var session = currentSession,
              let transcript = session.transcript,
              let provider = providerSettings.currentProvider()
        else {
            lastAnalysisError = "Сначала запиши и расшифруй интервью + настрой LLM-провайдера"
            return
        }

        streamingCustomTitle = template.name
        streamingCustomReply = ""
        isStreaming = true

        let prompt = AnalysisPrompts.notesTemplateUserPrompt(
            templateName:    template.name,
            templateContent: template.promptTemplate,
            transcript:      transcript,
            metadata:        session.metadata
        )

        streamingTask = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            do {
                let stream = provider.streamChat(
                    messages: [
                        ChatMessage(role: .system, content: AnalysisPrompts.systemRecruiterBase),
                        ChatMessage(role: .user,   content: prompt),
                    ],
                    transcript: transcript,
                    metadata:   session.metadata
                )
                for try await chunk in stream {
                    accumulated += chunk
                    self.streamingCustomReply = accumulated
                }
                if !accumulated.isEmpty {
                    let analysis = CustomAnalysis(
                        title:    template.name,
                        prompt:   "Шаблон: \(template.name)",
                        result:   accumulated,
                        provider: provider.providerInfo
                    )
                    session.customAnalyses.append(analysis)
                    try? self.store.save(session)
                    self.currentSession = session
                    self.refreshSessions()
                }
            } catch is CancellationError {
                // Quietly drop
            } catch {
                self.lastAnalysisError = "Шаблон «\(template.name)»: \(error.localizedDescription)"
            }
            self.streamingCustomReply = ""
            self.streamingCustomTitle = ""
            self.isStreaming = false
            self.streamingTask = nil
        }
    }

    /// Delete a previously saved custom analysis.
    func deleteCustomAnalysis(_ id: UUID) {
        guard var session = currentSession else { return }
        session.customAnalyses.removeAll { $0.id == id }
        try? store.save(session)
        currentSession = session
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
        export.audioTimePitchAlgorithm = .spectral

        // macOS 15+ async API — avoids bridging the legacy callback API
        // (which Swift 6 won't let us capture in a Sendable closure).
        try await export.export(to: target, as: .m4a)
    }
}
