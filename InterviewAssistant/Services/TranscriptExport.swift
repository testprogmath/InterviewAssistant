//
//  TranscriptExport.swift
//  InterviewAssistant
//
//  Renders a Session (transcript + any AI artefacts) as a portable Markdown
//  document. Used for both "Copy to clipboard" and "Save as .md".
//

import Foundation

enum TranscriptExport {

    /// Full Markdown report: metadata + transcript + every available analysis.
    static func renderMarkdown(for session: Session) -> String {
        var lines: [String] = []

        // Title + metadata
        let title = session.metadata.candidateName.map { "# Интервью с \($0)" }
            ?? "# Интервью"
        lines.append(title)
        lines.append("")
        lines.append(formattedMeta(session.metadata, sessionID: session.id))
        lines.append("")

        // Transcript
        if let transcript = session.transcript {
            lines.append("## Транскрипт")
            lines.append("")
            let showSpeaker = transcript.isMultiSpeaker
            for seg in transcript.segments {
                let mins = Int(seg.startTime) / 60
                let secs = Int(seg.startTime) % 60
                let ts   = String(format: "%02d:%02d", mins, secs)
                if showSpeaker {
                    lines.append("**[\(ts) · \(seg.speaker.localizedName)]** \(seg.text)")
                } else {
                    lines.append("**[\(ts)]** \(seg.text)")
                }
                lines.append("")
            }
        }

        // Summary
        if let s = session.summary {
            lines.append("## Саммари")
            lines.append("")
            lines.append(s.overallImpression)
            lines.append("")
            if !s.strengths.isEmpty {
                lines.append("### Сильные стороны")
                for x in s.strengths { lines.append("- \(x)") }
                lines.append("")
            }
            if !s.concerns.isEmpty {
                lines.append("### Опасения")
                for x in s.concerns { lines.append("- \(x)") }
                lines.append("")
            }
            if !s.highlights.isEmpty {
                let showSpeaker = session.transcript?.isMultiSpeaker ?? true
                lines.append("### Интересные моменты")
                for h in s.highlights {
                    let mins = Int(h.timestamp) / 60
                    let secs = Int(h.timestamp) % 60
                    let ts = String(format: "%02d:%02d", mins, secs)
                    if showSpeaker {
                        lines.append("- **\(ts) · \(h.speaker.localizedName):** «\(h.quote)» — \(h.why)")
                    } else {
                        lines.append("- **\(ts):** «\(h.quote)» — \(h.why)")
                    }
                }
                lines.append("")
            }
        }

        // SWOT
        if let w = session.swot {
            lines.append("## SWOT")
            lines.append("")
            appendSWOTSection(&lines, "💪 Сильные стороны (Strengths)",  items: w.strengths)
            appendSWOTSection(&lines, "📉 Слабые стороны (Weaknesses)",   items: w.weaknesses)
            appendSWOTSection(&lines, "🚀 Возможности (Opportunities)",   items: w.opportunities)
            appendSWOTSection(&lines, "⚠️ Угрозы (Threats)",              items: w.threats)
        }

        // Recommendation
        if let r = session.recommendation {
            lines.append("## Рекомендация")
            lines.append("")
            lines.append("**\(r.decision.localizedName)** (уверенность: \(Int(r.confidence * 100))%)")
            lines.append("")
            lines.append(r.rationale)
            lines.append("")
        }

        // Follow-up questions
        if !session.followUpQuestions.isEmpty {
            lines.append("## Уточняющие вопросы")
            lines.append("")
            for q in session.followUpQuestions {
                if let topic = q.topic, !topic.isEmpty {
                    lines.append("- **[\(topic)]** \(q.text)")
                } else {
                    lines.append("- \(q.text)")
                }
                if let r = q.rationale, !r.isEmpty {
                    lines.append("  - _\(r)_")
                }
            }
            lines.append("")
        }

        // Custom analyses
        for c in session.customAnalyses {
            lines.append("## \(c.title)")
            lines.append("")
            lines.append(c.result)
            lines.append("")
        }

        // Footer
        lines.append("---")
        lines.append("_Сгенерировано Интервью Ассистент_")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private

    private static func formattedMeta(_ m: InterviewMetadata, sessionID: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ru_RU")

        var parts: [String] = []
        parts.append("**Дата:** \(formatter.string(from: m.recordedAt))")
        if let p = m.position, !p.isEmpty { parts.append("**Позиция:** \(p)") }
        let mins = Int(m.duration) / 60
        let secs = Int(m.duration) % 60
        parts.append("**Длительность:** \(String(format: "%d:%02d", mins, secs))")
        return parts.joined(separator: " · ")
    }

    private static func appendSWOTSection(_ lines: inout [String], _ title: String, items: [String]) {
        lines.append("### \(title)")
        if items.isEmpty {
            lines.append("_не выявлено_")
        } else {
            for x in items { lines.append("- \(x)") }
        }
        lines.append("")
    }

    /// Suggested filename for "Save As…" dialog.
    static func suggestedFilename(for session: Session) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let date = formatter.string(from: session.metadata.recordedAt)

        let name = session.metadata.candidateName?
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if let name, !name.isEmpty {
            return "interview-\(name)-\(date).md"
        }
        return "interview-\(date).md"
    }
}
