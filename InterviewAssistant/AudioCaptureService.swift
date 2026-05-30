//
//  AudioCaptureService.swift
//  InterviewAssistant
//
//  Captures the interviewer (microphone) and the candidate (system audio
//  routed through the speakers) into two separate `.caf` files.
//
//  Two files instead of one mixed track gives us free, perfect diarisation:
//  Whisper transcribes each side separately and the speaker label is just
//  "which file did this come from".
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import OSLog
import CoreMedia

@MainActor
final class AudioCaptureService: NSObject, ObservableObject {

    // MARK: - Public state

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case stopping
        case error(String)
    }

    struct Recording {
        let interviewerURL: URL    // microphone only
        let candidateURL:   URL    // system audio only
        let startedAt:      Date
        let duration:       TimeInterval
    }

    @Published private(set) var state:           State = .idle
    @Published private(set) var elapsedSeconds:  Int   = 0

    // MARK: - Private state

    private let log = Logger(subsystem: "com.anna.interview", category: "AudioCapture")

    // Microphone side
    private let audioEngine = AVAudioEngine()
    private var micFile:     AVAudioFile?

    // System audio side (ScreenCaptureKit)
    private var stream:           SCStream?
    private var sysAudioFile:     AVAudioFile?
    private let sysAudioOutput    = SystemAudioOutput()

    // Timing
    private var startedAt:      Date?
    private var elapsedTimer:   Timer?

    // MARK: - Public API

    /// Start recording into the two URLs provided by the caller.
    /// The caller (typically `InterviewCoordinator`) owns the directory
    /// layout via `SessionStore`; this service is only responsible for
    /// writing audio bytes into the files it's been given.
    func start(interviewerURL: URL, candidateURL: URL) async {
        guard state == .idle || isError(state) else { return }
        state = .preparing

        do {
            // Make sure the parent directories exist (SessionStore should
            // have already created them, but belt-and-braces).
            let fm = FileManager.default
            try fm.createDirectory(at: interviewerURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: candidateURL.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            // System audio first — it triggers the Screen Recording permission prompt.
            try await startSystemAudio(at: candidateURL)
            // Then microphone.
            try startMicrophone(at: interviewerURL)

            startedAt = Date()
            elapsedSeconds = 0
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.elapsedSeconds = Int(Date().timeIntervalSince(s))
                }
            }

            state = .recording
            log.info("Recording started: interviewer=\(interviewerURL.lastPathComponent), candidate=\(candidateURL.lastPathComponent)")

        } catch {
            log.error("Start failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            await cleanup()
        }
    }

    func stop() async -> Recording? {
        guard state == .recording else { return nil }
        state = .stopping

        elapsedTimer?.invalidate()
        elapsedTimer = nil

        // Stop mic
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        let micURL = micFile?.url
        micFile = nil

        // Stop system audio
        if let stream {
            try? await stream.stopCapture()
        }
        let sysURL = sysAudioFile?.url
        sysAudioFile = nil
        sysAudioOutput.onBuffer = nil
        stream = nil

        guard let mic = micURL,
              let sys = sysURL,
              let started = startedAt
        else {
            state = .error("Не удалось сохранить файлы записи")
            return nil
        }

        let duration = Date().timeIntervalSince(started)
        startedAt = nil
        state = .idle

        log.info("Recording stopped: \(duration, format: .fixed(precision: 1)) sec")
        return Recording(
            interviewerURL: mic,
            candidateURL:   sys,
            startedAt:      started,
            duration:       duration
        )
    }

    // MARK: - Microphone

    private func startMicrophone(at url: URL) throws {
        let inputNode = audioEngine.inputNode

        // Enable Apple's voice processing on the mic input:
        //   • Acoustic Echo Cancellation — removes speaker echo from mic
        //   • Noise suppression
        //   • Automatic gain control
        //
        // The default behaviour also lowers ("ducks") other audio system-
        // wide, which on macOS hurts ScreenCaptureKit's candidate capture.
        // macOS 14+ lets us configure ducking explicitly — set it to MIN
        // so the candidate track stays loud and clear.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            log.info("Voice processing enabled on mic")

            if #available(macOS 14, *) {
                var config = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
                config.enableAdvancedDucking = false
                config.duckingLevel = .min
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = config
                log.info("Voice processing ducking minimised")
            }
        } catch {
            log.warning("Could not enable voice processing: \(error.localizedDescription) — mic may pick up speaker echo")
        }

        // On macOS the input node's format is only reliable after the engine
        // has been prepared. Use the *hardware* format directly.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        log.info("Mic HW format: \(hwFormat.sampleRate) Hz, \(hwFormat.channelCount) ch, interleaved=\(hwFormat.isInterleaved)")

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCapture", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Микрофон вернул нулевой формат — нет доступа?"])
        }

        let file = try AVAudioFile(forWriting: url, settings: hwFormat.settings)
        self.micFile = file

        // Pass nil as the tap format → AVAudioEngine uses the bus's true format.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            // Diagnostic: peak amplitude of this buffer
            let peak = buffer.peakAmplitude
            if peak > 0.001 {
                self.log.debug("Mic peak: \(peak, format: .fixed(precision: 4))")
            }

            do {
                try self.micFile?.write(from: buffer)
            } catch {
                self.log.error("Mic write error: \(error.localizedDescription)")
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        log.info("Microphone engine started")
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio(at url: URL) async throws {
        // ScreenCaptureKit requires picking a "shareable content" target.
        // We don't care about video — we want any display, just to attach to.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не найден дисплей для захвата системного звука"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio              = true
        config.excludesCurrentProcessAudio = true   // don't capture our own sounds
        config.sampleRate                  = 48_000
        config.channelCount                = 2
        // Video is required by the API even when we only want audio.
        // Make it as cheap as possible.
        config.width  = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)   // 1 fps
        config.queueDepth = 5

        // We'll open the file lazily once the first sample arrives (so we
        // can use the real incoming audio format). `url` here is the caller-
        // provided destination.
        sysAudioOutput.onBuffer = { [weak self] buffer in
            guard let self else { return }
            // Lazily open the file with the real incoming format
            if self.sysAudioFile == nil {
                self.log.info("Sys HW format: \(buffer.format.sampleRate) Hz, \(buffer.format.channelCount) ch, interleaved=\(buffer.format.isInterleaved)")
                do {
                    self.sysAudioFile = try AVAudioFile(
                        forWriting: url,
                        settings: buffer.format.settings
                    )
                } catch {
                    self.log.error("Could not open system audio file: \(error.localizedDescription)")
                    return
                }
            }

            // Diagnostic: peak amplitude
            let peak = buffer.peakAmplitude
            if peak > 0.001 {
                self.log.debug("Sys peak: \(peak, format: .fixed(precision: 4))")
            }

            do {
                try self.sysAudioFile?.write(from: buffer)
            } catch {
                self.log.error("System audio write error: \(error.localizedDescription)")
            }
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: sysAudioOutput)
        try stream.addStreamOutput(
            sysAudioOutput,
            type: .audio,
            sampleHandlerQueue: .global(qos: .userInitiated)
        )
        // We have to consume the video output too (to keep the stream alive),
        // but we'll just throw it away.
        try stream.addStreamOutput(
            sysAudioOutput,
            type: .screen,
            sampleHandlerQueue: .global(qos: .userInitiated)
        )

        try await stream.startCapture()
        self.stream = stream
        log.info("System audio started")
    }

    // MARK: - Helpers

    private func cleanup() async {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        micFile = nil
        sysAudioFile = nil
    }

    private func isError(_ s: State) -> Bool {
        if case .error = s { return true }
        return false
    }
}

// MARK: - System audio output handler

private final class SystemAudioOutput: NSObject, SCStreamDelegate, SCStreamOutput {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              let buffer = sampleBuffer.asPCMBuffer
        else { return }
        onBuffer?(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Logged by the service via state — nothing to do here.
    }
}

// MARK: - AVAudioPCMBuffer peak amplitude

extension AVAudioPCMBuffer {
    /// Peak absolute amplitude across all channels (0.0 ... 1.0 for normalised float).
    var peakAmplitude: Float {
        guard let data = floatChannelData else { return 0 }
        var peak: Float = 0
        let frames = Int(frameLength)
        let channels = Int(format.channelCount)
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<frames {
                let s = abs(samples[i])
                if s > peak { peak = s }
            }
        }
        return peak
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let format = AVAudioFormat(streamDescription: asbdPtr) else { return nil }

        let numSamples = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard numSamples > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: numSamples)
        else { return nil }
        buffer.frameLength = numSamples

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(numSamples),
            into: buffer.mutableAudioBufferList
        )
        return buffer
    }
}
