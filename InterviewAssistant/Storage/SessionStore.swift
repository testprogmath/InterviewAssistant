//
//  SessionStore.swift
//  InterviewAssistant
//
//  Filesystem-backed persistence for Session.
//
//  Layout on disk (inside the app's Documents folder):
//
//      Sessions/
//      └── <UUID>/
//          ├── session.json
//          ├── audio/
//          │   ├── interviewer.caf
//          │   └── candidate.caf
//          ├── transcripts/
//          │   ├── interviewer.json
//          │   ├── candidate.json
//          │   └── merged.json
//          ├── analyses/
//          │   ├── summary.json
//          │   ├── recommendation.json
//          │   ├── follow_ups.json
//          │   └── custom_<UUID>.json
//          └── exports/
//              └── transcript.md
//
//  This shape is intentionally hand-readable: each artefact is a small JSON
//  file that can be inspected, copied, re-generated, or deleted in isolation.
//

import Foundation
import OSLog

enum SessionStoreError: LocalizedError {
    case sessionNotFound(UUID)
    case readFailed(URL, underlying: Error)
    case writeFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Сессия \(id.uuidString) не найдена."
        case .readFailed(let url, let err):
            return "Не удалось прочитать \(url.lastPathComponent): \(err.localizedDescription)"
        case .writeFailed(let url, let err):
            return "Не удалось записать \(url.lastPathComponent): \(err.localizedDescription)"
        }
    }
}

final class SessionStore {

    // MARK: - Configuration

    private let baseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.anna.interview", category: "SessionStore")

    /// - Parameter baseURL: Custom location (mainly for tests). Defaults to
    ///                      `~/Documents/Sessions`.
    init(baseURL: URL? = nil) throws {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.baseURL = baseURL ?? documents.appendingPathComponent("Sessions", isDirectory: true)

        try FileManager.default.createDirectory(
            at: self.baseURL,
            withIntermediateDirectories: true
        )

        encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        log.info("SessionStore initialised at \(self.baseURL.path)")
    }

    // MARK: - Path helpers

    func sessionDirectory(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func audioDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("audio", isDirectory: true)
    }

    func transcriptsDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("transcripts", isDirectory: true)
    }

    func analysesDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("analyses", isDirectory: true)
    }

    func exportsDirectory(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("exports", isDirectory: true)
    }

    /// Returns the existing interviewer audio file (any supported extension)
    /// or, if none exists yet, the default `.caf` path that fresh recordings
    /// should write to.
    func interviewerAudioURL(for id: UUID) -> URL {
        resolveAudioURL(in: audioDirectory(for: id), baseName: "interviewer")
    }

    func candidateAudioURL(for id: UUID) -> URL {
        resolveAudioURL(in: audioDirectory(for: id), baseName: "candidate")
    }

    private func resolveAudioURL(in dir: URL, baseName: String) -> URL {
        let fm = FileManager.default
        for ext in ["caf", "m4a", "mp3", "wav", "mp4", "mov", "flac", "ogg"] {
            let url = dir.appendingPathComponent("\(baseName).\(ext)")
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        // Default for new recordings written by AudioCaptureService.
        return dir.appendingPathComponent("\(baseName).caf")
    }

    private func sessionFile(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("session.json")
    }

    // MARK: - CRUD

    /// Create a new session on disk and return it.
    /// All subdirectories (audio/, transcripts/, …) are created up front so
    /// later services can drop files into them without checking existence.
    func create(metadata: InterviewMetadata, id: UUID = UUID()) throws -> Session {
        let session = Session(id: id, metadata: metadata)
        try createDirectories(for: id)
        try save(session)
        log.info("Created session \(id.uuidString)")
        return session
    }

    func save(_ session: Session) throws {
        let url = sessionFile(for: session.id)
        do {
            let data = try encoder.encode(session)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SessionStoreError.writeFailed(url, underlying: error)
        }
    }

    func load(id: UUID) throws -> Session {
        let url = sessionFile(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(Session.self, from: data)
        } catch {
            throw SessionStoreError.readFailed(url, underlying: error)
        }
    }

    /// All sessions on disk, newest first. Corrupt sessions are skipped (logged).
    func loadAll() throws -> [Session] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var sessions: [Session] = []
        for entry in entries {
            guard
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                let id = UUID(uuidString: entry.lastPathComponent)
            else { continue }

            do {
                sessions.append(try load(id: id))
            } catch {
                log.warning("Skipped corrupt session \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return sessions.sorted { $0.metadata.recordedAt > $1.metadata.recordedAt }
    }

    func delete(id: UUID) throws {
        let dir = sessionDirectory(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw SessionStoreError.sessionNotFound(id)
        }
        try FileManager.default.removeItem(at: dir)
        log.info("Deleted session \(id.uuidString)")
    }

    // MARK: - Internal

    private func createDirectories(for id: UUID) throws {
        let fm = FileManager.default
        for dir in [
            sessionDirectory(for: id),
            audioDirectory(for: id),
            transcriptsDirectory(for: id),
            analysesDirectory(for: id),
            exportsDirectory(for: id),
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
