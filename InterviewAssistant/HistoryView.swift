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

    @State private var searchQuery: String = ""

    var body: some View {
        List(selection: $selection) {
            if !searchQuery.isEmpty {
                Section("Найдено: \(filteredSessions.count)") {
                    if filteredSessions.isEmpty {
                        Text("Ничего не найдено")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(filteredSessions) { session in
                            sessionRowView(session)
                        }
                    }
                }
            } else {
                ForEach(groupedSessions, id: \.label) { group in
                    Section(group.label) {
                        ForEach(group.sessions) { session in
                            sessionRowView(session)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchQuery, placement: .sidebar,
                    prompt: "Поиск по сессиям…")
        .toolbar {
            ToolbarItem {
                Button {
                    selection = nil
                    coordinator.reset()
                } label: {
                    Label("Новая запись", systemImage: "plus")
                }
                .help("Новая запись (⌘N)")
            }
            ToolbarItem {
                SettingsLink {
                    Label("Настройки", systemImage: "gearshape")
                }
                .help("Настройки (⌘,)")
            }
        }
        .onAppear {
            // On first appearance, also pick up any half-finished
            // transcriptions from previous app runs.
            coordinator.resumeIncompleteTranscriptions()
        }
    }

    // MARK: - Row + groups

    @ViewBuilder
    private func sessionRowView(_ session: Session) -> some View {
        SessionRow(
            session: session,
            isTranscribing: coordinator.transcribingSessionID == session.id,
            isQueued: coordinator.queuedTranscriptionIDs.contains(session.id)
        )
            .tag(session.id)
            .contextMenu {
                Button {
                    coordinator.revealInFinder(session.id)
                } label: {
                    Label("Открыть в Finder", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    coordinator.deleteSession(session.id)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
    }

    /// Group sessions into "Сегодня", "Вчера", "На этой неделе", "Раньше".
    private var groupedSessions: [(label: String, sessions: [Session])] {
        let calendar = Calendar.current
        let now = Date()

        var today:    [Session] = []
        var yesterday:[Session] = []
        var thisWeek: [Session] = []
        var earlier:  [Session] = []

        for s in coordinator.allSessions {
            let date = s.metadata.recordedAt
            if calendar.isDateInToday(date) {
                today.append(s)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(s)
            } else if let days = calendar.dateComponents([.day], from: date, to: now).day,
                      days <= 7 {
                thisWeek.append(s)
            } else {
                earlier.append(s)
            }
        }

        var result: [(label: String, sessions: [Session])] = []
        if !today.isEmpty     { result.append(("Сегодня",        today)) }
        if !yesterday.isEmpty { result.append(("Вчера",          yesterday)) }
        if !thisWeek.isEmpty  { result.append(("На этой неделе", thisWeek)) }
        if !earlier.isEmpty   { result.append(("Раньше",         earlier)) }
        return result
    }

    // MARK: - Filtering

    private var filteredSessions: [Session] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return coordinator.allSessions }

        return coordinator.allSessions.filter { session in
            matches(session, query: q)
        }
    }

    private func matches(_ session: Session, query q: String) -> Bool {
        if session.metadata.candidateName?.lowercased().contains(q) == true { return true }
        if session.metadata.position?.lowercased().contains(q)      == true { return true }

        if let segments = session.transcript?.segments {
            for seg in segments {
                if seg.text.lowercased().contains(q) { return true }
            }
        }
        if let imp = session.summary?.overallImpression.lowercased(),
           imp.contains(q) { return true }
        if let rec = session.recommendation?.rationale.lowercased(),
           rec.contains(q) { return true }

        return false
    }
}

// MARK: - Single row

private struct SessionRow: View {
    let session: Session
    var isTranscribing: Bool = false
    var isQueued: Bool = false

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

            if isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Транскрибируется…")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            } else if isQueued {
                Text("В очереди")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                badges
            }
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
