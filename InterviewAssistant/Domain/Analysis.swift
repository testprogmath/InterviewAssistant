//
//  Analysis.swift
//  InterviewAssistant
//
//  AI-generated artefacts derived from a Transcript. Each artefact carries
//  ProviderInfo so we always know what model produced it (and can re-run
//  with a different provider if needed).
//

import Foundation

// MARK: - Provider metadata

struct ProviderInfo: Codable, Hashable, Sendable {
    let providerID: String              // "ollama", "gigachat", "yandexgpt", ...
    let model:      String              // "qwen3:8b", "GigaChat-Pro", ...
    let costUSD:    Double?             // nil for local providers
    let timestamp:  Date

    init(providerID: String, model: String, costUSD: Double? = nil, timestamp: Date = Date()) {
        self.providerID = providerID
        self.model = model
        self.costUSD = costUSD
        self.timestamp = timestamp
    }
}

// MARK: - Summary

struct Summary: Codable, Hashable, Sendable {
    let strengths:  [String]
    let concerns:   [String]
    let highlights: [Highlight]         // notable moments with timestamps
    let overallImpression: String
    let provider:   ProviderInfo

    struct Highlight: Codable, Hashable, Sendable {
        let timestamp: TimeInterval     // seconds from start
        let speaker:   Speaker
        let quote:     String
        let why:       String           // why this moment is interesting
    }
}

// MARK: - Follow-up questions

struct FollowUpQuestion: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let text: String
    let rationale: String?              // why we should ask this
    let topic: String?                  // "Postgres experience", "Motivation"

    init(id: UUID = UUID(), text: String, rationale: String? = nil, topic: String? = nil) {
        self.id = id
        self.text = text
        self.rationale = rationale
        self.topic = topic
    }
}

// MARK: - Recommendation

struct Recommendation: Codable, Hashable, Sendable {
    enum Decision: String, Codable, CaseIterable, Sendable {
        case strongHire
        case hire
        case leanHire
        case leanNoHire
        case noHire
        case strongNoHire

        var localizedName: String {
            switch self {
            case .strongHire:   return "Однозначно нанимать"
            case .hire:         return "Нанимать"
            case .leanHire:     return "Скорее да"
            case .leanNoHire:   return "Скорее нет"
            case .noHire:       return "Не нанимать"
            case .strongNoHire: return "Однозначно нет"
            }
        }
    }

    let decision:   Decision
    let rationale:  String
    let confidence: Double              // 0…1, how confident the model is in this decision
    let provider:   ProviderInfo
}

// MARK: - SWOT

struct SWOTAnalysis: Codable, Hashable, Sendable {
    let strengths:     [String]   // S — что кандидат умеет хорошо
    let weaknesses:    [String]   // W — пробелы в знаниях/навыках/опыте
    let opportunities: [String]   // O — потенциал роста, что кандидат может дать компании
    let threats:       [String]   // T — риски найма (мотивация, культурный fit, нестабильность)
    let provider:      ProviderInfo
}

// MARK: - Custom analysis (free-form prompt)

struct CustomAnalysis: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title:     String               // user-chosen, e.g. "Культурный фит"
    let prompt:    String               // the original user prompt
    let result:    String               // markdown output
    let provider:  ProviderInfo

    init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        result: String,
        provider: ProviderInfo
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.result = result
        self.provider = provider
    }
}
