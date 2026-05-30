//
//  AnalysisProvider.swift
//  InterviewAssistant
//
//  Abstraction over LLM providers. The rest of the app talks only to this
//  protocol — switching from DeepSeek to YandexGPT to Ollama is a config
//  change, not a code change.
//
//  Design:
//    • Structured outputs (Summary / SWOT / Recommendation / FollowUps)
//      come back as fully-typed values via async throws. We coerce the
//      LLM to emit JSON internally; users see only the parsed object.
//    • Free-form outputs (custom analyses, chat) come back as async streams
//      of text fragments — UI can render them incrementally.
//

import Foundation

// MARK: - Chat primitives

struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    var id: UUID = UUID()
    let role: Role
    let content: String

    private enum CodingKeys: String, CodingKey {
        case role, content
    }
}

// MARK: - Provider identity (which model produced this artefact)

/// Lightweight identity exposed *before* a call is made. The cost field on
/// `ProviderInfo` lives on the actual artefact (Summary, Recommendation, …).
struct ProviderDescriptor: Equatable, Hashable, Sendable {
    let id:           String      // "deepseek", "yandexgpt", "ollama"
    let displayName:  String      // "DeepSeek", "YandexGPT", "Ollama (локально)"
    let defaultModel: String
}

// MARK: - Errors

enum AnalysisError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, body: String)
    case decoding(String, underlying: Error)
    case empty
    case cancelled
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m):  return "Провайдер не настроен: \(m)"
        case .http(let s, let body): return "HTTP \(s): \(body.prefix(300))"
        case .decoding(let m, _):    return "Не удалось разобрать ответ модели: \(m)"
        case .empty:                 return "Модель вернула пустой ответ"
        case .cancelled:             return "Операция отменена"
        case .transport(let e):      return "Сетевая ошибка: \(e.localizedDescription)"
        }
    }
}

// MARK: - The protocol everyone implements

protocol AnalysisProvider: Sendable {

    /// Static identity for logging and the Settings UI.
    var descriptor: ProviderDescriptor { get }

    /// What the implementation uses *right now*. Same fields are stored
    /// on every generated artefact so we always know who produced what.
    var providerInfo: ProviderInfo { get }

    // MARK: Structured outputs — JSON, batch

    func generateSummary(
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) async throws -> Summary

    func generateRecommendation(
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) async throws -> Recommendation

    func generateFollowUpQuestions(
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) async throws -> [FollowUpQuestion]

    func generateSWOT(
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) async throws -> SWOTAnalysis

    // MARK: Free-form outputs — streaming markdown / text

    func streamCustomAnalysis(
        title:      String,
        prompt:     String,
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) -> AsyncThrowingStream<String, Error>

    func streamChat(
        messages:   [ChatMessage],
        transcript: Transcript,
        metadata:   InterviewMetadata
    ) -> AsyncThrowingStream<String, Error>

    // MARK: Connectivity

    /// Cheap call that proves we can reach the model. Returns a short
    /// human-readable echo from the provider on success.
    func testConnection() async throws -> String
}
