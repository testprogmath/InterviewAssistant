//
//  ContentView.swift
//  InterviewAssistant
//
//  Front-end for InterviewCoordinator. Phase-5 UI: still minimal, but every
//  interview is now persisted as a Session with audio + transcript on disk.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {

    @StateObject private var coordinator: InterviewCoordinator

    @State private var candidateName: String = ""
    @State private var position:      String = ""
    @State private var selectedSessionID: UUID?
    @State private var showingFilePicker = false
    @State private var showingExportSheet = false
    @State private var clipboardConfirmation = false

    init(providerSettings: ProviderSettings) {
        // SessionStore can throw (filesystem); if it fails we fall back to
        // a temp directory so the app still runs.
        let store: SessionStore = {
            do { return try SessionStore() }
            catch {
                let fallback = FileManager.default.temporaryDirectory
                    .appendingPathComponent("InterviewAssistant-fallback", isDirectory: true)
                return (try? SessionStore(baseURL: fallback)) ?? {
                    fatalError("Could not create SessionStore: \(error)")
                }()
            }
        }()

        let coordinator = InterviewCoordinator(
            store:            store,
            capture:          AudioCaptureService(),
            transcription:    TranscriptionService(),
            providerSettings: providerSettings
        )
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some View {
        NavigationSplitView {
            HistoryView(coordinator: coordinator, selection: $selectedSessionID)
                .frame(minWidth: 240)
        } detail: {
            detailView
        }
        .onChange(of: selectedSessionID) { _, newID in
            if let id = newID {
                coordinator.loadSession(id)
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .mpeg4Audio],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .fileExporter(
            isPresented: $showingExportSheet,
            document: exportDocument,
            contentType: .text,
            defaultFilename: exportFilename
        ) { _ in /* nothing */ }
    }

    @ViewBuilder
    private var detailView: some View {
        ScrollView {
            VStack(spacing: 24) {

                Text("Интервью Ассистент")
                    .font(.title)
                    .fontWeight(.semibold)

                // ── Candidate metadata ──────────────────────────────
                if coordinator.state == .idle {
                    candidateFields
                }

                // ── Recording controls ──────────────────────────────
                VStack(spacing: 12) {
                    Text(stateLabel)
                        .font(.headline)
                        .foregroundStyle(stateColor)

                    Text(formatElapsed(coordinator.elapsedSeconds))
                        .font(.system(size: 44, weight: .ultraLight, design: .monospaced))

                    if coordinator.state == .transcribing {
                        transcriptionProgressView
                    }

                    primaryButton

                    if showsImportButton {
                        Button {
                            showingFilePicker = true
                        } label: {
                            Label("Импорт аудио/видео", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.link)
                    }
                }

                // ── Current session info ────────────────────────────
                if let session = coordinator.currentSession {
                    sessionCard(session)
                }

                // ── Transcript ──────────────────────────────────────
                if let segments = coordinator.currentSession?.transcript?.segments,
                   !segments.isEmpty {
                    transcriptList(segments)
                }

                // ── Analysis ───────────────────────────────────────
                if coordinator.currentSession?.transcript != nil {
                    analysisSection
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 540)
    }

    // MARK: - Analysis

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI-анализ")
                    .font(.headline)
                Spacer()
                if let kind = coordinator.ongoingAnalysis {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Генерируем: \(kind)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                analysisButton(.summary)
                analysisButton(.swot)
                analysisButton(.recommendation)
                analysisButton(.followUps)
            }

            if let err = coordinator.lastAnalysisError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err).font(.callout)
                    Spacer()
                    Button("✕") { coordinator.clearAnalysisError() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if let summary = coordinator.currentSession?.summary {
                summaryCard(summary)
            }
            if let swot = coordinator.currentSession?.swot {
                swotCard(swot)
            }
            if let rec = coordinator.currentSession?.recommendation {
                recommendationCard(rec)
            }
            if let fups = coordinator.currentSession?.followUpQuestions,
               !fups.isEmpty {
                followUpCard(fups)
            }
        }
        .padding(.top, 16)
    }

    private func analysisButton(_ kind: InterviewCoordinator.AnalysisKind) -> some View {
        Button {
            Task { await coordinator.runAnalysis(kind) }
        } label: {
            Text(kind.rawValue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .disabled(coordinator.ongoingAnalysis != nil)
    }

    private func summaryCard(_ s: Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader("Саммари", provider: s.provider)
            Text(s.overallImpression).font(.body)
            if !s.strengths.isEmpty {
                Text("Сильные стороны").font(.subheadline.bold())
                ForEach(Array(s.strengths.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                }
            }
            if !s.concerns.isEmpty {
                Text("Опасения").font(.subheadline.bold())
                ForEach(Array(s.concerns.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                }
            }
            if !s.highlights.isEmpty {
                Text("Интересные моменты").font(.subheadline.bold())
                ForEach(Array(s.highlights.enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%02d:%02d — %@",
                                    Int(h.timestamp) / 60, Int(h.timestamp) % 60,
                                    h.speaker.localizedName))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("«\(h.quote)»").italic()
                        Text(h.why).font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .cardStyle()
    }

    private func swotCard(_ s: SWOTAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader("SWOT-анализ", provider: s.provider)
            swotSection("💪 Strengths",     items: s.strengths)
            swotSection("📉 Weaknesses",    items: s.weaknesses)
            swotSection("🚀 Opportunities", items: s.opportunities)
            swotSection("⚠️ Threats",        items: s.threats)
        }
        .cardStyle()
    }

    private func swotSection(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            if items.isEmpty {
                Text("(не выявлено)").foregroundStyle(.secondary).font(.caption)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                    Text("• \(line)")
                }
            }
        }
    }

    private func recommendationCard(_ r: Recommendation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader("Рекомендация", provider: r.provider)
            HStack {
                Text(r.decision.localizedName)
                    .font(.title3.bold())
                    .foregroundStyle(decisionColor(r.decision))
                Spacer()
                Text("Уверенность: \(Int(r.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(r.rationale)
        }
        .cardStyle()
    }

    private func followUpCard(_ list: [FollowUpQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Уточняющие вопросы")
                .font(.headline)
            ForEach(list) { q in
                VStack(alignment: .leading, spacing: 4) {
                    if let topic = q.topic, !topic.isEmpty {
                        Text(topic)
                            .font(.caption.bold())
                            .foregroundStyle(.blue)
                    }
                    Text(q.text)
                    if let r = q.rationale, !r.isEmpty {
                        Text(r).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func cardHeader(_ title: String, provider: ProviderInfo) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Text("\(provider.providerID) · \(provider.model)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func decisionColor(_ d: Recommendation.Decision) -> Color {
        switch d {
        case .strongHire:   return .green
        case .hire:         return .green.opacity(0.8)
        case .leanHire:     return .yellow
        case .leanNoHire:   return .orange
        case .noHire:       return .red.opacity(0.8)
        case .strongNoHire: return .red
        }
    }

    // MARK: - Subviews

    private var candidateFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Имя кандидата (необязательно)", text: $candidateName)
                .textFieldStyle(.roundedBorder)
            TextField("Позиция (необязательно)", text: $position)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 360)
    }

    private var primaryButton: some View {
        Button(action: primaryAction) {
            Text(primaryButtonLabel)
                .font(.headline)
                .frame(width: 240, height: 44)
                .background(primaryButtonColor)
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isPrimaryDisabled)
    }

    private func sessionCard(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сессия")
                    .font(.headline)
                Spacer()
                if coordinator.state == .ready {
                    Button("Новая запись", action: coordinator.reset)
                        .buttonStyle(.link)
                }
            }
            if let name = session.metadata.candidateName, !name.isEmpty {
                Text("Кандидат: \(name)")
            }
            if let pos = session.metadata.position, !pos.isEmpty {
                Text("Позиция: \(pos)")
            }
            Text("Длительность: \(Int(session.metadata.duration)) сек")
            Text("ID: \(session.id.uuidString)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func transcriptList(_ segments: [TranscriptSegment]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Транскрипт (\(segments.count) сегментов)")
                    .font(.headline)
                Spacer()
                Button {
                    copyMarkdownToClipboard()
                } label: {
                    Label(clipboardConfirmation ? "Скопировано ✓" : "Копировать",
                          systemImage: "doc.on.doc")
                }
                .help("Скопировать транскрипт + анализ в буфер обмена")

                Button {
                    showingExportSheet = true
                } label: {
                    Label("Сохранить .md", systemImage: "arrow.down.doc")
                }
                .help("Сохранить как Markdown-файл")

                Menu {
                    Button("Перетранскрибировать") {
                        Task { await coordinator.retranscribe() }
                    }
                    .disabled(coordinator.state == .transcribing)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ForEach(segments) { seg in
                SegmentRow(segment: seg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Computed

    private var stateLabel: String {
        switch coordinator.state {
        case .idle:           return "Готов к записи"
        case .preparing:      return "Запрашиваем доступ…"
        case .recording:      return "Идёт запись"
        case .stopping:       return "Сохраняем…"
        case .transcribing:   return "Транскрибируем (это занимает время)…"
        case .ready:          return "Готово"
        case .failed(let m):  return "Ошибка: \(m)"
        }
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .recording:                  return .red
        case .preparing, .stopping, .transcribing: return .orange
        case .failed:                     return .red
        case .ready:                      return .green
        default:                          return .secondary
        }
    }

    private var primaryButtonLabel: String {
        switch coordinator.state {
        case .recording:    return "Остановить"
        case .transcribing: return "Транскрибируем…"
        case .ready:        return "Новое интервью"
        default:            return "Начать запись"
        }
    }

    private var primaryButtonColor: Color {
        switch coordinator.state {
        case .recording: return .red
        case .ready:     return .green
        default:         return .blue
        }
    }

    private var isPrimaryDisabled: Bool {
        switch coordinator.state {
        case .preparing, .stopping, .transcribing: return true
        default: return false
        }
    }

    // MARK: - Actions

    private func primaryAction() {
        switch coordinator.state {
        case .recording:
            Task { await coordinator.stopAndProcess() }
        case .ready:
            coordinator.reset()
        default:
            Task {
                await coordinator.startInterview(
                    candidateName: candidateName.isEmpty ? nil : candidateName,
                    position:      position.isEmpty      ? nil : position
                )
            }
        }
    }

    private func formatElapsed(_ s: Int) -> String {
        String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    // MARK: - Transcription progress

    @ViewBuilder
    private var transcriptionProgressView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = coordinator.transcriptionFraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("WhisperKit · large-v3-turbo · ANE")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if !coordinator.transcriptionPreview.isEmpty {
                Text(coordinator.transcriptionPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: 500)
        .padding(.vertical, 6)
    }

    // MARK: - Import / Export

    private var showsImportButton: Bool {
        switch coordinator.state {
        case .idle, .ready, .failed: return true
        default: return false
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else { return }

        // macOS will hand us a security-scoped URL; access must be opened.
        let needsScope = url.startAccessingSecurityScopedResource()
        Task {
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            await coordinator.importFile(
                from: url,
                candidateName: candidateName.isEmpty ? nil : candidateName,
                position:      position.isEmpty      ? nil : position
            )
        }
    }

    private func copyMarkdownToClipboard() {
        guard let session = coordinator.currentSession else { return }
        let md = TranscriptExport.renderMarkdown(for: session)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(md, forType: .string)

        clipboardConfirmation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            clipboardConfirmation = false
        }
    }

    private var exportDocument: MarkdownDocument? {
        guard let session = coordinator.currentSession else { return nil }
        return MarkdownDocument(text: TranscriptExport.renderMarkdown(for: session))
    }

    private var exportFilename: String {
        guard let session = coordinator.currentSession else { return "interview.md" }
        return TranscriptExport.suggestedFilename(for: session)
    }
}

// MARK: - File document wrapper for .fileExporter

struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.text, .plainText] }
    static var writableContentTypes: [UTType] { [.text, .plainText] }

    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Single segment row

private struct SegmentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            Text(segment.speaker.localizedName)
                .font(.caption.bold())
                .foregroundStyle(segment.speaker == .interviewer ? .blue : .green)
                .frame(width: 90, alignment: .leading)

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var timestamp: String {
        let total = Int(segment.startTime)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - View modifiers

private extension View {
    func cardStyle() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    ContentView(providerSettings: ProviderSettings())
}
