//
//  Speaker.swift
//  InterviewAssistant
//
//  Identity of who is speaking. In our two-track architecture the speaker
//  is determined at recording time (mic vs. system audio), so this is just
//  a label — not the output of any diarisation algorithm.
//

import Foundation

enum Speaker: String, Codable, CaseIterable, Identifiable, Sendable {
    case interviewer
    case candidate

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .interviewer: return "Интервьюер"
        case .candidate:   return "Кандидат"
        }
    }
}
