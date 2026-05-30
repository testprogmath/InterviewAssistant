//
//  OpenAICompatibleProvider.swift
//  InterviewAssistant
//
//  One concrete AnalysisProvider that speaks the OpenAI Chat Completions
//  protocol. DeepSeek, OpenAI proper, OpenRouter and Together all expose
//  the same shape, so swapping providers is just a base-URL change.
//
//  Use the static factories at the bottom of the file:
//      .deepSeek(apiKey:)
//      .openAI(apiKey:)
//

import Foundation
import OSLog

final class OpenAICompatibleProvider: AnalysisProvider, @unchecked Sendable {

    // MARK: - Identity

    let descriptor: ProviderDescriptor
    let model: String

    var providerInfo: ProviderInfo {
        ProviderInfo(providerID: descriptor.id, model: model)
    }

    // MARK: - Internals

    private let baseURL: URL
    private let apiKey:  String
    private let session: URLSession
    private let log = Logger(subsystem: "com.anna.interview", category: "OpenAICompat")

    // MARK: - Init

    init(
        descriptor: ProviderDescriptor,
        baseURL:    URL,
        apiKey:     String,
        model:      String
    ) {
        self.descriptor = descriptor
        self.baseURL    = baseURL
        self.apiKey     = apiKey
        self.model      = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 60      // connect / first byte
        config.timeoutIntervalForResource = 600     // total — LLMs can be slow
        self.session = URLSession(configuration: config)
    }

    // MARK: - Structured outputs

    func generateSummary(
        transcript: Transcript,
        metadata: InterviewMetadata
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

        let text = try await chatCompletion(
            messages: [
                .system(AnalysisPrompts.systemRecruiterBase),
                .user(AnalysisPrompts.summaryUserPrompt(transcript: transcript, metadata: metadata)),
            ],
            jsonMode: true,
            temperature: 0.3
        )
        let dto = try JSONExtractor.decode(DTO.self, from: text)

        return Summary(
            strengths:  dto.strengths,
            concerns:   dto.concerns,
            highlights: dto.highlights.map {
                Summary.Highlight(
                    timestamp: $0.timestamp,
                    speaker:   Speaker(rawValue: $0.speaker) ?? .candidate,
                    quote:     $0.quote,
                    why:       $0.why
                )
            },
            overallImpression: dto.overallImpression,
            provider: providerInfo
        )
    }

    func generateRecommendation(
        transcript: Transcript,
        metadata: InterviewMetadata
    ) async throws -> Recommendation {

        struct DTO: Decodable {
            let decision:   String
            let rationale:  String
            let confidence: Double
        }

        let text = try await chatCompletion(
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
        transcript: Transcript,
        metadata: InterviewMetadata
    ) async throws -> [FollowUpQuestion] {

        struct DTO: Decodable {
            let questions: [Q]
            struct Q: Decodable {
                let text:      String
                let topic:     String?
                let rationale: String?
            }
        }

        let text = try await chatCompletion(
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
        transcript: Transcript,
        metadata: InterviewMetadata
    ) async throws -> SWOTAnalysis {

        struct DTO: Decodable {
            let strengths:     [String]
            let weaknesses:    [String]
            let opportunities: [String]
            let threats:       [String]
        }

        let text = try await chatCompletion(
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
        msgs.append(contentsOf: messages.map { Wire.Message(role: $0.role.rawValue, content: $0.content) })

        return streamChatRaw(messages: msgs, temperature: 0.4)
    }

    // MARK: - Connectivity

    func testConnection() async throws -> String {
        let echo = try await chatCompletion(
            messages: [
                .user("Скажи 'OK' и больше ничего."),
            ],
            jsonMode: false,
            temperature: 0,
            maxTokens: 10
        )
        return "\(descriptor.displayName) (\(model)): \(echo.prefix(40))"
    }

    // MARK: - HTTP helpers

    /// Single, non-streaming chat completion. Returns the assistant text.
    private func chatCompletion(
        messages: [Wire.Message],
        jsonMode: Bool = false,
        temperature: Double = 0.5,
        maxTokens: Int? = nil
    ) async throws -> String {

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json",  forHTTPHeaderField: "Content-Type")

        let body = Wire.Request(
            model:          model,
            messages:       messages,
            temperature:    temperature,
            max_tokens:     maxTokens,
            stream:         false,
            response_format: jsonMode ? .init(type: "json_object") : nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let parsed = try JSONDecoder().decode(Wire.Response.self, from: data)
        guard let content = parsed.choices.first?.message.content, !content.isEmpty else {
            throw AnalysisError.empty
        }
        return content
    }

    /// Server-sent events streaming version. Yields text fragments.
    private func streamChatRaw(
        messages: [Wire.Message],
        temperature: Double
    ) -> AsyncThrowingStream<String, Error> {

        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json",  forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body = Wire.Request(
                        model:          model,
                        messages:       messages,
                        temperature:    temperature,
                        max_tokens:     nil,
                        stream:         true,
                        response_format: nil
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        // Drain the body to a string for the error message
                        var buf = Data()
                        for try await b in bytes { buf.append(b) }
                        throw AnalysisError.http(status: http.statusCode,
                                                 body: String(data: buf, encoding: .utf8) ?? "")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst("data: ".count)
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(Wire.StreamChunk.self, from: data),
                              let delta = chunk.choices.first?.delta.content,
                              !delta.isEmpty else { continue }
                        continuation.yield(delta)
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

// MARK: - Wire types (private to file)

private enum Wire {

    struct Message: Codable {
        let role: String
        let content: String

        static func system(_ s: String) -> Message { .init(role: "system",    content: s) }
        static func user(_ s: String)   -> Message { .init(role: "user",      content: s) }
        static func assistant(_ s: String) -> Message { .init(role: "assistant", content: s) }
    }

    struct Request: Codable {
        let model: String
        let messages: [Message]
        let temperature: Double?
        let max_tokens: Int?
        let stream: Bool
        let response_format: ResponseFormat?

        struct ResponseFormat: Codable {
            let type: String   // "json_object" | "text"
        }
    }

    struct Response: Codable {
        struct Choice: Codable {
            let message: Message
        }
        let choices: [Choice]
    }

    struct StreamChunk: Codable {
        struct Choice: Codable {
            struct Delta: Codable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }
}

// MARK: - Factory presets

extension OpenAICompatibleProvider {

    static func deepSeek(apiKey: String, model: String = "deepseek-chat") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            descriptor: ProviderDescriptor(
                id:           "deepseek",
                displayName:  "DeepSeek",
                defaultModel: "deepseek-chat"
            ),
            baseURL: URL(string: "https://api.deepseek.com")!,
            apiKey:  apiKey,
            model:   model
        )
    }

    static func openAI(apiKey: String, model: String = "gpt-5-mini") -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            descriptor: ProviderDescriptor(
                id:           "openai",
                displayName:  "OpenAI",
                defaultModel: "gpt-5-mini"
            ),
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey:  apiKey,
            model:   model
        )
    }

    static func openRouter(apiKey: String, model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            descriptor: ProviderDescriptor(
                id:           "openrouter",
                displayName:  "OpenRouter",
                defaultModel: model
            ),
            baseURL: URL(string: "https://openrouter.ai/api")!,
            apiKey:  apiKey,
            model:   model
        )
    }
}
