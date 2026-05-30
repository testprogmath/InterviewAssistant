//
//  OllamaProvider.swift
//  InterviewAssistant
//
//  AnalysisProvider implementation talking to a locally running Ollama
//  daemon at http://localhost:11434.
//
//  Ollama's API differs from OpenAI's: the chat endpoint is `/api/chat`,
//  streaming uses NDJSON (newline-delimited JSON) instead of SSE, and
//  structured output is requested via `format: "json"` rather than
//  `response_format`.
//
//  No API key needed; the user just has to have `ollama serve` running.
//

import Foundation
import OSLog

final class OllamaProvider: AnalysisProvider, @unchecked Sendable {

    // MARK: - Identity

    let descriptor: ProviderDescriptor
    let model: String

    var providerInfo: ProviderInfo {
        ProviderInfo(providerID: descriptor.id, model: model)
    }

    // MARK: - Internals

    private let baseURL: URL
    private let session: URLSession
    private let log = Logger(subsystem: "com.anna.interview", category: "Ollama")

    // MARK: - Init

    init(model: String = "qwen3:8b",
         baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.descriptor = ProviderDescriptor(
            id:           "ollama",
            displayName:  "Ollama (локально)",
            defaultModel: "qwen3:8b"
        )
        self.model   = model
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        // Ollama on CPU/Metal can be slow on large prompts.
        config.timeoutIntervalForRequest  = 120
        config.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: config)
    }

    // MARK: - Structured outputs

    func generateSummary(
        transcript: Transcript, metadata: InterviewMetadata
    ) async throws -> Summary {
        struct DTO: Decodable {
            let overallImpression: String
            let strengths:  [String]
            let concerns:   [String]
            let highlights: [HL]
            struct HL: Decodable {
                let timestamp: Double
                let speaker:   String
                let quote:     String
                let why:       String
            }
        }

        let text = try await chat(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.summaryUserPrompt(transcript: transcript, metadata: metadata)),
            ],
            jsonMode: true,
            temperature: 0.3
        )
        let dto = try JSONExtractor.decode(DTO.self, from: text)

        return Summary(
            strengths:         dto.strengths,
            concerns:          dto.concerns,
            highlights: dto.highlights.map {
                Summary.Highlight(
                    timestamp: $0.timestamp,
                    speaker:   Speaker(rawValue: $0.speaker) ?? .candidate,
                    quote:     $0.quote,
                    why:       $0.why
                )
            },
            overallImpression: dto.overallImpression,
            provider:          providerInfo
        )
    }

    func generateRecommendation(
        transcript: Transcript, metadata: InterviewMetadata
    ) async throws -> Recommendation {
        struct DTO: Decodable {
            let decision:   String
            let rationale:  String
            let confidence: Double
        }

        let text = try await chat(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.recommendationUserPrompt(transcript: transcript, metadata: metadata)),
            ],
            jsonMode: true,
            temperature: 0.2
        )
        let dto = try JSONExtractor.decode(DTO.self, from: text)

        let decision = Recommendation.Decision(rawValue: dto.decision) ?? .leanNoHire
        return Recommendation(
            decision:   decision,
            rationale:  dto.rationale,
            confidence: max(0, min(1, dto.confidence)),
            provider:   providerInfo
        )
    }

    func generateFollowUpQuestions(
        transcript: Transcript, metadata: InterviewMetadata
    ) async throws -> [FollowUpQuestion] {
        struct DTO: Decodable {
            let questions: [Q]
            struct Q: Decodable {
                let text:      String
                let topic:     String?
                let rationale: String?
            }
        }

        let text = try await chat(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.followUpsUserPrompt(transcript: transcript, metadata: metadata)),
            ],
            jsonMode: true,
            temperature: 0.5
        )
        let dto = try JSONExtractor.decode(DTO.self, from: text)
        return dto.questions.map {
            FollowUpQuestion(text: $0.text, rationale: $0.rationale, topic: $0.topic)
        }
    }

    func generateSWOT(
        transcript: Transcript, metadata: InterviewMetadata
    ) async throws -> SWOTAnalysis {
        struct DTO: Decodable {
            let strengths:     [String]
            let weaknesses:    [String]
            let opportunities: [String]
            let threats:       [String]
        }

        let text = try await chat(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.swotUserPrompt(transcript: transcript, metadata: metadata)),
            ],
            jsonMode: true,
            temperature: 0.4
        )
        let dto = try JSONExtractor.decode(DTO.self, from: text)
        return SWOTAnalysis(
            strengths:     dto.strengths,
            weaknesses:    dto.weaknesses,
            opportunities: dto.opportunities,
            threats:       dto.threats,
            provider:      providerInfo
        )
    }

    // MARK: - Streaming outputs

    func streamCustomAnalysis(
        title: String,
        prompt: String,
        transcript: Transcript,
        metadata: InterviewMetadata
    ) -> AsyncThrowingStream<String, Error> {
        streamChatRaw(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.customUserPrompt(
                    userPrompt: prompt, transcript: transcript, metadata: metadata
                )),
            ],
            temperature: 0.5
        )
    }

    func streamChat(
        messages: [ChatMessage],
        transcript: Transcript,
        metadata: InterviewMetadata
    ) -> AsyncThrowingStream<String, Error> {
        var msgs: [Wire.Message] = [
            .system(AnalysisPrompts.chatSystemPrompt(transcript: transcript, metadata: metadata))
        ]
        msgs.append(contentsOf: messages.map {
            Wire.Message(role: $0.role.rawValue, content: $0.content)
        })
        return streamChatRaw(messages: msgs, temperature: 0.4)
    }

    // MARK: - Connectivity

    func testConnection() async throws -> String {
        // Cheap probe: GET /api/tags lists installed models. Doesn't even
        // load the chat model into memory.
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"

        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data)

            struct Tags: Decodable {
                struct M: Decodable { let name: String }
                let models: [M]
            }
            let tags = (try? JSONDecoder().decode(Tags.self, from: data))
                ?? Tags(models: [])
            let names = tags.models.map(\.name)
            let has = names.contains { $0.hasPrefix(model.split(separator: ":").first.map(String.init) ?? model) }

            if has {
                return "Ollama: модель \(model) готова."
            } else if names.isEmpty {
                return "Ollama запущен, но модели не установлены. Выполни: ollama pull \(model)"
            } else {
                return "Ollama запущен. Модель \(model) не найдена. Установленные: \(names.prefix(3).joined(separator: ", "))"
            }
        } catch {
            throw AnalysisError.transport(error)
        }
    }

    // MARK: - HTTP helpers

    /// Single non-streaming chat completion. Collects the full assistant text.
    private func chat(
        messages: [Wire.Message],
        jsonMode: Bool = false,
        temperature: Double = 0.5,
        maxTokens: Int? = nil
    ) async throws -> String {

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = Wire.Request(
            model:    model,
            messages: messages,
            stream:   false,
            format:   jsonMode ? "json" : nil,
            options:  .init(
                temperature: temperature,
                num_predict: maxTokens,
                num_ctx:     8192
            )
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let parsed = try JSONDecoder().decode(Wire.Response.self, from: data)
        guard !parsed.message.content.isEmpty else {
            throw AnalysisError.empty
        }
        return parsed.message.content
    }

    /// NDJSON streaming version. Yields content fragments as they arrive.
    private func streamChatRaw(
        messages: [Wire.Message],
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {

        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body = Wire.Request(
                        model:    model,
                        messages: messages,
                        stream:   true,
                        format:   nil,
                        options:  .init(
                            temperature: temperature,
                            num_predict: 2048,
                            num_ctx:     8192
                        )
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var buf = Data()
                        for try await b in bytes { buf.append(b) }
                        throw AnalysisError.http(status: http.statusCode,
                                                 body: String(data: buf, encoding: .utf8) ?? "")
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              let data = trimmed.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(Wire.StreamChunk.self, from: data)
                        else { continue }

                        if !chunk.message.content.isEmpty {
                            continuation.yield(chunk.message.content)
                        }
                        if chunk.done {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AnalysisError.cancelled)
                } catch let e as AnalysisError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AnalysisError.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AnalysisError.transport(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnalysisError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}

// MARK: - Wire types

private enum Wire {

    struct Message: Codable {
        let role: String
        let content: String

        static func system(_ s: String) -> Message    { .init(role: "system",    content: s) }
        static func user(_ s: String) -> Message      { .init(role: "user",      content: s) }
        static func assistant(_ s: String) -> Message { .init(role: "assistant", content: s) }
    }

    struct Request: Codable {
        let model:    String
        let messages: [Message]
        let stream:   Bool
        let format:   String?       // "json" or nil
        let options:  Options

        struct Options: Codable {
            let temperature: Double
            let num_predict: Int?
            let num_ctx:     Int
        }
    }

    struct Response: Codable {
        let message: Message
        let done:    Bool
    }

    struct StreamChunk: Codable {
        let message: Message
        let done:    Bool
    }
}
