//
//  Session.swift
//  InterviewAssistant
//
//  Top-level aggregate: one interview = one Session.
//
//  Audio files live next to the JSON on disk (managed by SessionStore) but
//  are not embedded in this struct — their paths are computed from the
//  session ID. This keeps the model portable and easy to inspect.
//

import Foundation

struct InterviewMetadata: Codable, Hashable, Sendable {
    var candidateName: String?
    var position:      String?
    let recordedAt:    Date
    let duration:      TimeInterval     // seconds

    init(
        candidateName: String? = nil,
        position: String? = nil,
        recordedAt: Date = Date(),
        duration: TimeInterval = 0
    ) {
        self.candidateName = candidateName
        self.position = position
        self.recordedAt = recordedAt
        self.duration = duration
    }
}

struct Session: Codable, Identifiable, Sendable {
    /// Bump when the on-disk shape changes and SessionStore needs to migrate.
    static let currentSchemaVersion = 1

    let id: UUID
    let schemaVersion: Int

    var metadata: InterviewMetadata

    var transcript: Transcript?

    var summary:            Summary?
    var swot:               SWOTAnalysis?
    var followUpQuestions:  [FollowUpQuestion]
    var recommendation:     Recommendation?
    var customAnalyses:     [CustomAnalysis]

    init(
        id: UUID = UUID(),
        schemaVersion: Int = Session.currentSchemaVersion,
        metadata: InterviewMetadata,
        transcript: Transcript? = nil,
        summary: Summary? = nil,
        swot: SWOTAnalysis? = nil,
        followUpQuestions: [FollowUpQuestion] = [],
        recommendation: Recommendation? = nil,
        customAnalyses: [CustomAnalysis] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.metadata = metadata
        self.transcript = transcript
        self.summary = summary
        self.swot = swot
        self.followUpQuestions = followUpQuestions
        self.recommendation = recommendation
        self.customAnalyses = customAnalyses
    }

    /// Convenience: has the heavy work (transcription) finished?
    var isTranscribed: Bool { transcript != nil }
}
