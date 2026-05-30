//
//  NotesTemplate.swift
//  InterviewAssistant
//
//  A reusable "notes recipe" the user can apply to any interview.
//
//  The user supplies an example or instructions (`promptTemplate`). When
//  applied to a session, the LLM uses it as a style/structure guide and
//  produces notes in the same shape based on the transcript.
//

import Foundation

struct NotesTemplate: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String              // "Технический скрининг", "Софт-скиллы"
    var promptTemplate: String    // the example / instructions for the LLM
    var description: String       // optional: what this is for
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        promptTemplate: String,
        description: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.promptTemplate = promptTemplate
        self.description = description
        self.createdAt = createdAt
    }
}
