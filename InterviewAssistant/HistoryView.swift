//
//  HistoryView.swift
//  InterviewAssistant
//
//  Sidebar list of all persisted sessions. Selecting one loads it into
//  the coordinator and the main detail view re-renders to show it.
//

import SwiftUI

struct HistoryView: View {

    @ObservedObject var coordinator: InterviewCoordinator
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            Section("Сессии") {
                ForEach(coordinator.allSessions) { session in
                    SessionRow(session: session)
                        .tag(session.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                coordinator.deleteSession(session.id)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    selection = nil
                    coordinator.reset()
                } label: {
                    Label("Новая запись", systemImage: "plus")
                }
                .help("Новая запись")
            }
        }
        .onAppear {
            coordinator.refreshSessions()
        }
    }
}

// MARK: - Single row

private struct SessionRow: View {
    let session: Session

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                durationBadge
            }
            Text(Self.dateFormatter.string(from: session.metadata.recordedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            badges
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        if let name = session.metadata.candidateName, !name.isEmpty { return name }
        return "Без имени"
    }

    private var durationBadge: some View {
        let mins = Int(session.metadata.duration) / 60
        let secs = Int(session.metadata.duration) % 60
        return Text(String(format: "%d:%02d", mins, secs))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if session.transcript != nil       { badge("📝", "Транскрипт") }
            if session.summary != nil          { badge("📋", "Саммари") }
            if session.swot != nil             { badge("⚡", "SWOT") }
            if session.recommendation != nil   { badge("✅", "Решение") }
            if !session.followUpQuestions.isEmpty { badge("❓", "Вопросы") }
        }
    }

    private func badge(_ emoji: String, _ help: String) -> some View {
        Text(emoji)
            .font(.caption2)
            .help(help)
    }
}
