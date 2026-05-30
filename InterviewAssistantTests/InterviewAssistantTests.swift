//
//  InterviewAssistantTests.swift
//  InterviewAssistantTests
//

import Testing
import Foundation
@testable import InterviewAssistant

// MARK: - JSONExtractor

@Suite("JSONExtractor")
struct JSONExtractorTests {

    struct Sample: Decodable, Equatable {
        let name: String
        let count: Int
    }

    @Test("Decodes a clean JSON object")
    func cleanJSON() throws {
        let input = #"{"name": "Anna", "count": 3}"#
        let s = try JSONExtractor.decode(Sample.self, from: input)
        #expect(s == Sample(name: "Anna", count: 3))
    }

    @Test("Strips ```json fences")
    func jsonFences() throws {
        let input = """
        ```json
        {"name": "Анна", "count": 5}
        ```
        """
        let s = try JSONExtractor.decode(Sample.self, from: input)
        #expect(s.name == "Анна")
        #expect(s.count == 5)
    }

    @Test("Strips plain ``` fences")
    func plainFences() throws {
        let input = "```\n{\"name\":\"x\",\"count\":1}\n```"
        let s = try JSONExtractor.decode(Sample.self, from: input)
        #expect(s.count == 1)
    }

    @Test("Finds JSON wrapped in prose")
    func proseWrapping() throws {
        let input = """
        Вот результат:
        {"name": "X", "count": 42}
        Надеюсь, помог.
        """
        let s = try JSONExtractor.decode(Sample.self, from: input)
        #expect(s.count == 42)
    }

    @Test("Throws when no JSON present")
    func noJSON() {
        #expect(throws: AnalysisError.self) {
            try JSONExtractor.decode(Sample.self, from: "ничего полезного")
        }
    }
}

// MARK: - SpeakerMergeService

@Suite("SpeakerMergeService")
struct SpeakerMergeTests {

    private func seg(_ speaker: Speaker, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, startTime: start, endTime: end, text: text)
    }

    @Test("Interleaves by startTime")
    func interleaves() {
        let i = [seg(.interviewer, 0, 2, "Привет"),
                 seg(.interviewer, 10, 12, "Спасибо")]
        let c = [seg(.candidate, 3, 9, "Здравствуйте")]
        let merged = SpeakerMergeService().merge(interviewer: i, candidate: c, coalesceWithinGap: nil)
        #expect(merged.map(\.speaker) == [.interviewer, .candidate, .interviewer])
        #expect(merged.map(\.startTime) == [0, 3, 10])
    }

    @Test("Coalesces adjacent same-speaker segments")
    func coalesces() {
        let i = [seg(.interviewer, 0, 2, "Привет."),
                 seg(.interviewer, 2.2, 4, "Как дела?")]
        let merged = SpeakerMergeService().merge(interviewer: i, candidate: [], coalesceWithinGap: 0.4)
        #expect(merged.count == 1)
        #expect(merged.first?.text == "Привет. Как дела?")
        #expect(merged.first?.endTime == 4)
    }

    @Test("Does not coalesce across the gap threshold")
    func doesntCoalesceLargeGap() {
        let i = [seg(.interviewer, 0, 2, "А"),
                 seg(.interviewer, 5, 6, "Б")]
        let merged = SpeakerMergeService().merge(interviewer: i, candidate: [], coalesceWithinGap: 0.4)
        #expect(merged.count == 2)
    }

    @Test("Empty + empty = empty")
    func empties() {
        #expect(SpeakerMergeService().merge(interviewer: [], candidate: []).isEmpty)
    }
}

// MARK: - TranscriptChunker

@Suite("TranscriptChunker")
struct ChunkerTests {

    private func transcript(of length: Int) -> Transcript {
        let segments = (0..<length).map { i in
            TranscriptSegment(
                speaker:   i % 2 == 0 ? .interviewer : .candidate,
                startTime: TimeInterval(i),
                endTime:   TimeInterval(i + 1),
                text:      String(repeating: "слово ", count: 50)
            )
        }
        return Transcript(
            segments:        segments,
            language:        "ru",
            durationSeconds: TimeInterval(length),
            modelInfo:       TranscriptionModelInfo(provider: "x", model: "y", version: "1"),
            createdAt:       Date()
        )
    }

    @Test("Short transcript stays in one chunk")
    func short() {
        let t = transcript(of: 3)
        let chunks = TranscriptChunker.chunk(t, maxChars: 6000)
        #expect(chunks.count == 1)
        #expect(chunks[0].segments.count == 3)
    }

    @Test("Long transcript is split")
    func long() {
        let t = transcript(of: 100)
        let chunks = TranscriptChunker.chunk(t, maxChars: 2000)
        #expect(chunks.count > 1)
        let total = chunks.flatMap(\.segments).count
        #expect(total == 100)
    }

    @Test("Chunks respect the character budget (roughly)")
    func budget() {
        let t = transcript(of: 50)
        let chunks = TranscriptChunker.chunk(t, maxChars: 2000)
        for chunk in chunks {
            let chars = chunk.segments.map { $0.text.count + 32 }.reduce(0, +)
            #expect(chars <= 2000 + 400)
        }
    }
}

// MARK: - AnalysisPrompts

@Suite("AnalysisPrompts")
struct PromptTests {

    @Test("Single-speaker transcript hides speaker labels")
    func singleSpeaker() {
        let segs = [
            TranscriptSegment(speaker: .candidate, startTime: 0,  endTime: 5,  text: "Hello"),
            TranscriptSegment(speaker: .candidate, startTime: 10, endTime: 20, text: "World"),
        ]
        let t = Transcript(
            segments:        segs,
            language:        "ru",
            durationSeconds: 20,
            modelInfo:       TranscriptionModelInfo(provider: "x", model: "y", version: "1")
        )
        let formatted = AnalysisPrompts.formatTranscript(t)
        #expect(!formatted.contains("Кандидат"))
        #expect(!formatted.contains("Интервьюер"))
        #expect(formatted.contains("Hello"))
        #expect(formatted.contains("World"))
    }

    @Test("Multi-speaker transcript shows labels")
    func multiSpeaker() {
        let segs = [
            TranscriptSegment(speaker: .interviewer, startTime: 0, endTime: 5, text: "Q"),
            TranscriptSegment(speaker: .candidate,   startTime: 5, endTime: 10, text: "A"),
        ]
        let t = Transcript(
            segments:        segs,
            language:        "ru",
            durationSeconds: 10,
            modelInfo:       TranscriptionModelInfo(provider: "x", model: "y", version: "1")
        )
        let formatted = AnalysisPrompts.formatTranscript(t)
        #expect(formatted.contains("Интервьюер"))
        #expect(formatted.contains("Кандидат"))
    }
}

// MARK: - SessionStore

@Suite("SessionStore")
struct SessionStoreTests {

    private func tempStore() throws -> (SessionStore, URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterviewAssistant-Tests-\(UUID().uuidString)")
        let store = try SessionStore(baseURL: temp)
        return (store, temp)
    }

    @Test("Round-trip create / load")
    func roundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let meta = InterviewMetadata(candidateName: "Анна", position: "iOS Eng", duration: 100)
        let created = try store.create(metadata: meta)
        let loaded  = try store.load(id: created.id)

        #expect(loaded.metadata.candidateName == "Анна")
        #expect(loaded.metadata.position      == "iOS Eng")
        #expect(loaded.schemaVersion == Session.currentSchemaVersion)
    }

    @Test("loadAll returns newest first")
    func sortOrder() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s1 = try store.create(metadata: InterviewMetadata(recordedAt: Date(timeIntervalSinceNow: -100), duration: 10))
        let s2 = try store.create(metadata: InterviewMetadata(recordedAt: Date(), duration: 10))

        let all = try store.loadAll()
        #expect(all.first?.id == s2.id)
        #expect(all.last?.id  == s1.id)
    }

    @Test("Delete removes the session folder")
    func delete() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let s = try store.create(metadata: InterviewMetadata(duration: 10))
        try store.delete(id: s.id)
        #expect(throws: SessionStoreError.self) {
            try store.load(id: s.id)
        }
    }
}
