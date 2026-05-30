//
//  TranscriptionService.swift
//  InterviewAssistant
//
//  Wraps WhisperKit. Loads `large-v3-turbo` lazily on first use, transcribes
//  one audio file at a time into [TranscriptSegment]s. The caller decides
//  which Speaker label to attach, since speaker identity is determined at
//  capture time (mic = interviewer, system audio = candidate).
//
//  VAD chunking is enabled — silent stretches are skipped, which is a big
//  win for our two-track architecture (each track is silent half the time).
//

import Foundation
import OSLog
import WhisperKit
import AVFoundation

@MainActor
final class TranscriptionService: ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        case loadingModel    // downloading and/or warming up
        case ready
        case transcribing    // WhisperKit 0.13+ does not expose a stable
                             // fractionCompleted; we leave finer progress
                             // to a future iteration.
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Set once the model is loaded — exposed for diagnostics / UI.
    @Published private(set) var modelInfo: TranscriptionModelInfo?

    /// Fraction of the current file processed so far, 0…1.
    /// `nil` when not transcribing or duration is unknown.
    @Published private(set) var progressFraction: Double?

    /// Latest snippet of text the model emitted — useful as "we're alive" UI.
    @Published private(set) var progressPreview: String = ""

    // MARK: - Configuration

    /// Argmax-compiled Core ML variant of Whisper large-v3-turbo.
    /// Roughly 1.5 GB on disk, runs on ANE on Apple Silicon.
    private let modelName: String

    /// Hugging Face repo that hosts pre-compiled WhisperKit models.
    private let modelRepo = "argmaxinc/whisperkit-coreml"

    private let log = Logger(subsystem: "com.anna.interview", category: "Transcription")

    private var whisperKit: WhisperKit?

    /// Shared Task for model loading. Ensures that if two callers ask for
    /// the model at the same time, only one download runs and both await
    /// the same result.
    private var loadTask: Task<WhisperKit, Error>?

    // MARK: - Init

    /// If `modelName` is nil, the user's current selection (`WhisperSettings`)
    /// is read from UserDefaults. Pass an explicit name in tests.
    init(modelName: String? = nil) {
        self.modelName = modelName ?? WhisperSettings.currentModelID()
    }

    // MARK: - Public API

    /// Ensure the model is downloaded and loaded into memory.
    /// Safe to call repeatedly — only does work once.
    func prewarm() async throws {
        _ = try await ensureLoaded()
    }

    /// Transcribe a single audio file. The caller specifies which Speaker
    /// this track belongs to; the service simply tags every returned segment
    /// with that label.
    ///
    /// Cancel by cancelling the surrounding `Task`.
    func transcribe(
        audioURL: URL,
        as speaker: Speaker,
        language: String = "ru"
    ) async throws -> [TranscriptSegment] {

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionError.fileNotFound(audioURL)
        }

        let wk = try await ensureLoaded()

        state = .transcribing
        progressFraction = 0
        progressPreview  = ""
        log.info("Transcribing \(audioURL.lastPathComponent) as \(speaker.rawValue)…")

        // Probe duration so we can report a meaningful percentage.
        let totalSeconds = await Self.audioDurationSeconds(of: audioURL)

        let options = DecodingOptions(
            verbose:                    false,
            task:                       .transcribe,
            language:                   language,
            temperature:                0,
            skipSpecialTokens:          true,    // strip <|startoftranscript|> etc.
            withoutTimestamps:          true,    // strip inline <|1.00|> tokens
            wordTimestamps:             false,
            // More permissive thresholds — works better for mic tracks that
            // pick up room echo or background noise from speakers.
            compressionRatioThreshold:  2.4,
            logProbThreshold:           -1.5,
            noSpeechThreshold:          0.3,
            chunkingStrategy:           .vad
        )

        do {
            let results = try await wk.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options,
                callback: { [weak self] progress in
                    // Each WhisperKit window is ~30 seconds of audio. We
                    // use `windowId` as the cheapest possible progress
                    // signal — close enough for a UI indicator.
                    let processed = Double(progress.windowId + 1) * 30
                    let fraction: Double? = totalSeconds > 0
                        ? min(1, max(0, processed / totalSeconds))
                        : nil
                    let snippet = String(progress.text.suffix(160))

                    Task { @MainActor [weak self] in
                        self?.progressFraction = fraction
                        self?.progressPreview  = snippet
                    }
                    return !Task.isCancelled
                }
            )

            if Task.isCancelled {
                throw CancellationError()
            }

            let segments = Self.convert(results, speaker: speaker)
            state = .ready
            progressFraction = nil
            progressPreview  = ""
            log.info("Done: \(segments.count) segments")
            return segments

        } catch {
            state = .failed(error.localizedDescription)
            progressFraction = nil
            progressPreview  = ""
            log.error("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    private static func audioDurationSeconds(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        do {
            let d = try await asset.load(.duration)
            return d.seconds.isFinite ? d.seconds : 0
        } catch {
            return 0
        }
    }

    // MARK: - Internal

    private func ensureLoaded() async throws -> WhisperKit {
        if let wk = whisperKit { return wk }

        // Re-use an in-flight load if there is one.
        if let existing = loadTask {
            return try await existing.value
        }

        state = .loadingModel
        log.info("Loading WhisperKit model: \(self.modelName)")

        let task = Task<WhisperKit, Error> { [modelName, modelRepo] in
            let config = WhisperKitConfig(
                model:     modelName,
                modelRepo: modelRepo,
                verbose:   false,
                logLevel:  .info,
                prewarm:   true,
                load:      true,
                download:  true
            )
            return try await WhisperKit(config)
        }
        loadTask = task

        do {
            let wk = try await task.value
            whisperKit = wk
            modelInfo = TranscriptionModelInfo(
                provider: "whisperkit",
                model:    modelName,
                version:  Self.whisperKitVersion
            )
            state = .ready
            log.info("Model loaded.")
            return wk
        } catch {
            // Clear so the next call can retry the download.
            loadTask = nil
            state = .failed("Не удалось загрузить модель: \(error.localizedDescription)")
            log.error("Model load failed: \(error.localizedDescription)")
            throw TranscriptionError.modelLoadFailed(underlying: error)
        }
    }

    /// Best-effort conversion of WhisperKit results into our domain type.
    private static func convert(
        _ results: [TranscriptionResult],
        speaker: Speaker
    ) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = cleanText(seg.text)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    speaker:    speaker,
                    startTime:  TimeInterval(seg.start),
                    endTime:    TimeInterval(seg.end),
                    text:       text,
                    confidence: confidence(from: seg.avgLogprob)
                ))
            }
        }
        return out
    }

    /// Strip leftover Whisper special tokens like `<|startoftranscript|>`
    /// or inline timestamps like `<|1.00|>` and trim whitespace. Belt-and-
    /// braces: DecodingOptions should already prevent these, but quantised
    /// turbo models occasionally let one slip through.
    private static func cleanText(_ raw: String) -> String {
        let withoutTokens = raw.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: "",
            options: .regularExpression
        )
        return withoutTokens
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    /// Whisper reports `avg_logprob` in roughly [-1, 0]; map to a 0…1 score
    /// via exp(), which is the probability of that segment in log space.
    private static func confidence(from avgLogprob: Float) -> Double {
        let clamped = min(0, max(-3, Double(avgLogprob)))
        return exp(clamped)
    }

    /// Hardcoded for now; ideally pulled from Bundle / package metadata.
    private static let whisperKitVersion = "0.9"
}

// MARK: - Errors

enum TranscriptionError: LocalizedError {
    case fileNotFound(URL)
    case modelLoadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Аудиофайл не найден: \(url.lastPathComponent)"
        case .modelLoadFailed(let err):
            return "Не удалось загрузить модель Whisper: \(err.localizedDescription)"
        }
    }
}
