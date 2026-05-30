//
//  AnalysisPrompts.swift
//  InterviewAssistant
//
//  All the Russian-language prompts the analysis layer uses. Centralised
//  so providers (DeepSeek / YandexGPT / Ollama / …) share the same
//  instructions and we only tune them once.
//
//  Convention for structured outputs: we ask the model to return a single
//  JSON object matching a fixed schema. The schema is described in the
//  prompt; providers may additionally pass `response_format: json_object`
//  to the API. We always parse defensively (strip code fences, search
//  for the first/last brace) before decoding.
//

import Foundation

enum AnalysisPrompts {

    // MARK: - Shared

    static let systemRecruiterBase = """
    Ты — опытный технический рекрутер с многолетней практикой. \
    Отвечай строго на русском языке. Будь конкретным и опирайся ТОЛЬКО \
    на содержание транскрипта интервью. Не выдумывай факты, которых нет \
    в транскрипте. Если данных недостаточно — так и напиши.
    """

    /// Renders a transcript as `[Спикер] текст` lines with timestamps,
    /// suitable for inclusion in an LLM prompt.
    static func formatTranscript(_ transcript: Transcript) -> String {
        transcript.segments
            .map { seg in
                let mins = Int(seg.startTime) / 60
                let secs = Int(seg.startTime) % 60
                let ts   = String(format: "%02d:%02d", mins, secs)
                return "[\(ts) \(seg.speaker.localizedName)] \(seg.text)"
            }
            .joined(separator: "\n")
    }

    /// Header that tells the model who the candidate is.
    static func candidateHeader(_ metadata: InterviewMetadata) -> String {
        var parts: [String] = []
        if let name = metadata.candidateName, !name.isEmpty {
            parts.append("Имя: \(name)")
        }
        if let pos = metadata.position, !pos.isEmpty {
            parts.append("Позиция: \(pos)")
        }
        parts.append("Длительность интервью: \(Int(metadata.duration / 60)) мин")
        return parts.joined(separator: " · ")
    }

    // MARK: - Summary

    static let summarySchema = """
    {
      "overallImpression": "1-2 параграфа общего впечатления",
      "strengths":  ["сильная сторона 1", "сильная сторона 2"],
      "concerns":   ["опасение 1", "опасение 2"],
      "highlights": [
        {
          "timestamp": 125.0,
          "speaker": "candidate",
          "quote": "цитата из транскрипта",
          "why": "почему этот момент достоин внимания"
        }
      ]
    }
    """

    static func summaryUserPrompt(transcript: Transcript, metadata: InterviewMetadata) -> String {
        """
        Составь краткое структурированное резюме интервью.

        \(candidateHeader(metadata))

        Верни ровно ОДИН JSON-объект следующей схемы (никакого текста до или после):
        \(summarySchema)

        Поля:
        • overallImpression — общее впечатление, 3-5 предложений
        • strengths — массив строк, сильные стороны
        • concerns — массив строк, риски или опасения (если нет — пустой массив)
        • highlights — 1-3 интересных момента из транскрипта с цитатой и таймкодом в секундах

        Транскрипт:
        \(formatTranscript(transcript))
        """
    }

    // MARK: - SWOT

    static let swotSchema = """
    {
      "strengths":     ["S1", "S2"],
      "weaknesses":    ["W1", "W2"],
      "opportunities": ["O1", "O2"],
      "threats":       ["T1", "T2"]
    }
    """

    static func swotUserPrompt(transcript: Transcript, metadata: InterviewMetadata) -> String {
        """
        Проведи SWOT-анализ кандидата на основе транскрипта интервью.

        \(candidateHeader(metadata))

        Верни ровно ОДИН JSON-объект следующей схемы (никакого текста до или после):
        \(swotSchema)

        Семантика полей:
        • strengths     — что кандидат явно умеет хорошо
        • weaknesses    — пробелы в знаниях, навыках или опыте
        • opportunities — потенциал роста, как кандидат может принести пользу компании
        • threats       — риски найма: мотивация, культурный fit, нестабильность

        Каждый пункт — короткая фраза 1-2 предложения. Если данных по разделу нет — \
        верни пустой массив, не выдумывай.

        Транскрипт:
        \(formatTranscript(transcript))
        """
    }

    // MARK: - Recommendation

    static let recommendationSchema = """
    {
      "decision": "strongHire | hire | leanHire | leanNoHire | noHire | strongNoHire",
      "rationale": "2-4 предложения почему",
      "confidence": 0.0
    }
    """

    static func recommendationUserPrompt(transcript: Transcript, metadata: InterviewMetadata) -> String {
        """
        Дай рекомендацию по найму этого кандидата.

        \(candidateHeader(metadata))

        Верни ровно ОДИН JSON-объект следующей схемы:
        \(recommendationSchema)

        • decision — одно из значений: strongHire, hire, leanHire, leanNoHire, noHire, strongNoHire
        • rationale — 2-4 предложения, обоснование решения, опираясь на конкретные моменты интервью
        • confidence — твоя уверенность в этом решении, число от 0 до 1

        Транскрипт:
        \(formatTranscript(transcript))
        """
    }

    // MARK: - Follow-up questions

    static let followUpsSchema = """
    {
      "questions": [
        { "text": "Вопрос?", "topic": "Тема", "rationale": "Зачем спрашивать" }
      ]
    }
    """

    static func followUpsUserPrompt(transcript: Transcript, metadata: InterviewMetadata) -> String {
        """
        Предложи 3-5 уточняющих вопросов, которые стоит задать кандидату на \
        следующем этапе. Цель — закрыть пробелы и проверить риски, обнаруженные \
        в этом интервью.

        \(candidateHeader(metadata))

        Верни ровно ОДИН JSON-объект следующей схемы:
        \(followUpsSchema)

        Каждый вопрос:
        • text — сам вопрос на русском
        • topic — короткая тема (например, "Опыт с PostgreSQL", "Мотивация")
        • rationale — почему именно этот вопрос полезен

        Транскрипт:
        \(formatTranscript(transcript))
        """
    }

    // MARK: - Custom analysis (free-form)

    static func customUserPrompt(
        userPrompt: String,
        transcript: Transcript,
        metadata: InterviewMetadata
    ) -> String {
        """
        \(candidateHeader(metadata))

        Задача пользователя:
        \(userPrompt)

        Ответ дай в виде markdown — заголовки уровня ## для основных разделов, \
        маркированные списки где уместно. Опирайся ТОЛЬКО на транскрипт.

        Транскрипт:
        \(formatTranscript(transcript))
        """
    }

    // MARK: - Chat

    static func chatSystemPrompt(transcript: Transcript, metadata: InterviewMetadata) -> String {
        """
        \(systemRecruiterBase)

        Ты обсуждаешь с рекрутером следующее интервью. Все ответы давай на \
        основе транскрипта ниже. Если пользователь спрашивает что-то, чего \
        в транскрипте нет — так и скажи.

        \(candidateHeader(metadata))

        Транскрипт интервью:
        \(formatTranscript(transcript))
        """
    }
}

// MARK: - JSON extraction helper

enum JSONExtractor {
    /// LLMs occasionally wrap JSON in ```json fences or sprinkle prose
    /// around it. Find the outermost {…} block and decode that.
    static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let cleaned = stripCodeFences(raw)
        guard let json = extractOutermostJSONObject(cleaned),
              let data = json.data(using: .utf8) else {
            throw AnalysisError.decoding("Не нашёл JSON-объект в ответе", underlying: NSError(domain: "JSONExtractor", code: -1))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AnalysisError.decoding("\(error)", underlying: error)
        }
    }

    private static func stripCodeFences(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "```json") { t.removeSubrange(t.startIndex..<r.upperBound) }
        else if let r = t.range(of: "```") { t.removeSubrange(t.startIndex..<r.upperBound) }
        if let r = t.range(of: "```", options: .backwards) { t.removeSubrange(r.lowerBound..<t.endIndex) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractOutermostJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{"),
              let end   = s.lastIndex(of: "}"),
              start < end else { return nil }
        return String(s[start...end])
    }
}
