//
//  AudioPlayerService.swift
//  InterviewAssistant
//
//  Plays a session's audio back, optionally seeking to a transcript
//  timestamp. If both interviewer and candidate tracks exist, they are
//  combined into one AVMutableComposition so the user hears the whole
//  conversation in sync.
//

import Foundation
import AVFoundation
import Combine
import OSLog

@MainActor
final class AudioPlayerService: ObservableObject {

    @Published private(set) var currentSessionID: UUID?
    @Published private(set) var currentTime:  TimeInterval = 0
    @Published private(set) var duration:     TimeInterval = 0
    @Published private(set) var isPlaying:    Bool = false

    private let log = Logger(subsystem: "com.anna.interview", category: "AudioPlayer")
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver:  Any?

    // MARK: - Lifecycle

    /// Prepare playback for the given session. Idempotent — calling with
    /// the same session ID does nothing.
    func load(session: Session, store: SessionStore) async {
        if currentSessionID == session.id, player != nil { return }
        stop()

        let item = await makePlayerItem(for: session, store: store)
        let player = AVPlayer(playerItem: item)
        self.player = player
        self.currentSessionID = session.id

        // Probe the duration as soon as it becomes available.
        if let d = try? await item.asset.load(.duration) {
            let secs = d.seconds
            self.duration = secs.isFinite ? secs : 0
        }

        // Tick currentTime every 0.1s.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 1000),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds.isFinite ? time.seconds : 0
            }
        }

        // Auto-pause at end.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
            }
        }
    }

    /// Seek and play. Loads the session first if needed.
    func play(at time: TimeInterval, session: Session, store: SessionStore) async {
        await load(session: session, store: store)
        seek(to: time)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        let t = CMTime(seconds: max(0, time), preferredTimescale: 1000)
        player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = max(0, time)
    }

    func stop() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        if let obs = endObserver  { NotificationCenter.default.removeObserver(obs) }
        timeObserver = nil
        endObserver  = nil
        player?.pause()
        player = nil
        currentSessionID = nil
        currentTime = 0
        duration    = 0
        isPlaying   = false
    }

    // MARK: - Internal

    /// Build a player item that has the mic + system audio mixed (if both
    /// exist), otherwise plays the single available track.
    private func makePlayerItem(for session: Session, store: SessionStore) async -> AVPlayerItem {
        let fm = FileManager.default
        let interviewerURL = store.interviewerAudioURL(for: session.id)
        let candidateURL   = store.candidateAudioURL(for: session.id)

        let interviewerExists = fm.fileExists(atPath: interviewerURL.path)
        let candidateExists   = fm.fileExists(atPath: candidateURL.path)

        // Single-track? Just play it.
        if !interviewerExists, candidateExists {
            return AVPlayerItem(url: candidateURL)
        }
        if interviewerExists, !candidateExists {
            return AVPlayerItem(url: interviewerURL)
        }

        // Both tracks — combine into one composition.
        let composition = AVMutableComposition()

        func addTrack(from url: URL) async {
            let asset = AVURLAsset(url: url)
            do {
                let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
                guard let sourceTrack = sourceTracks.first,
                      let dest = composition.addMutableTrack(
                          withMediaType: .audio,
                          preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else { return }
                let duration = try await asset.load(.duration)
                try dest.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: .zero
                )
            } catch {
                log.warning("Could not add track from \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if interviewerExists { await addTrack(from: interviewerURL) }
        if candidateExists   { await addTrack(from: candidateURL) }

        let composedTracks = (try? await composition.loadTracks(withMediaType: .audio)) ?? []
        if composedTracks.isEmpty {
            // Nothing usable — fall back to candidate URL (will fail
            // gracefully when played).
            return AVPlayerItem(url: candidateURL)
        }
        return AVPlayerItem(asset: composition)
    }
}
