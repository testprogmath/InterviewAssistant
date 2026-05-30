//
//  Transcript.swift
//  InterviewAssistant
//
//  Structured representation of a transcribed interview.
//
//  Every segment carries its own timestamps and speaker label so the data
//  can be searched, navigated, and analysed without re-parsing prose.
//

import Foundation

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let speaker: Speaker
    let startTime: TimeInterval         // seconds from the start of the recording
    let endTime:   TimeInterval
    let text: String
    let confidence: Double?             // 0…1 if the ASR engine reports it

    init(
        id: UUID = UUID(),
        speaker: Speaker,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        confidence: Double? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.confidence = confidence
    }

    var duration: TimeInterval { endTime - startTime }
}

struct Transcript: Codable, Hashable, Sendable {
    let segments: [TranscriptSegment]
    let language: String                // e.g. "ru"
    let durationSeconds: TimeInterval
    let modelInfo: TranscriptionModelInfo
    let createdAt: Date

    init(
        segments: [TranscriptSegment],
        language: String,
        durationSeconds: TimeInterval,
        modelInfo: TranscriptionModelInfo,
        createdAt: Date = Date()
    ) {
        self.segments = segments
        self.language = language
        self.durationSeconds = durationSeconds
        self.modelInfo = modelInfo
        self.createdAt = createdAt
    }

    var fullText: String {
        segments
            .map { "[\($0.speaker.localizedName)] \($0.text)" }
            .joined(separator: "\n")
    }
}

struct TranscriptionModelInfo: Codable, Hashable, Sendable {
    let provider: String                // "whisperkit"
    let model:    String                // "large-v3-turbo"
    let version:  String                // WhisperKit package version
}
