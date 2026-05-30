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
    @StateObject private var audioPlayer = AudioPlayerService()
    @ObservedObject  var templates: NotesTemplateStore
    private let sessionStore: SessionStore

    @State private var candidateName: String = ""
    @State private var position:      String = ""
    @State private var selectedSessionID: UUID?
    @State private var showingFilePicker = false
    @State private var showingExportSheet = false
    @State private var clipboardConfirmation = false
    @State private var customAnalysisTitle: String = ""
    @State private var customAnalysisPrompt: String = ""
    @State private var chatDraft: String = ""
    @State private var transcriptExpanded: Bool = false

    init(providerSettings: ProviderSettings, templates: NotesTemplateStore) {
        self.templates = templates
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
        self.sessionStore = store

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
            audioPlayer.stop()
            transcriptExpanded = false       // collapse on session switch
            if let id = newID {
                coordinator.loadSession(id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newInterviewShortcut)) { _ in
            selectedSessionID = nil
            audioPlayer.stop()
            coordinator.reset()
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

    @State private var isDraggedOver = false

    @ViewBuilder
    private var detailView: some View {
        ScrollView {
            VStack(spacing: 24) {

                Text("Интервью Ассистент")
                    .font(.title)
                    .fontWeight(.semibold)

                // ── First-launch welcome ────────────────────────────
                if coordinator.allSessions.isEmpty && coordinator.currentSession == nil {
                    welcomeBanner
                }

                // ── Candidate metadata ──────────────────────────────
                if coordinator.state == .idle && coordinator.currentSession == nil {
                    candidateFields
                }

                // ── Recording controls ──────────────────────────────
                VStack(spacing: 12) {
                    Text(stateLabel)
                        .font(.headline)
                        .foregroundStyle(stateColor)

                    Text(formatElapsed(coordinator.elapsedSeconds))
                        .font(.system(size: 44, weight: .ultraLight, design: .monospaced))

                    if isCurrentSessionTranscribing {
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

                    customAnalysisSection
                    chatSection
                }
            }
            .padding(24)
        }
        .frame(minWidth: 600, minHeight: 540)
        .overlay {
            if isDraggedOver {
                ZStack {
                    Color.blue.opacity(0.18)
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 48))
                        Text("Отпусти, чтобы импортировать")
                            .font(.headline)
                    }
                    .foregroundStyle(.blue)
                }
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDraggedOver) { providers in
            handleDroppedProviders(providers)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await coordinator.importFile(
                    from: url,
                    candidateName: candidateName.isEmpty ? nil : candidateName,
                    position:      position.isEmpty      ? nil : position
                )
            }
        }
        return true
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

            if !templates.templates.isEmpty {
                Menu {
                    ForEach(templates.templates) { t in
                        Button(t.name) {
                            coordinator.applyNotesTemplate(t)
                        }
                    }
                } label: {
                    Label("Применить шаблон заметок", systemImage: "doc.text")
                }
                .disabled(coordinator.isStreaming)
                .menuStyle(.borderlessButton)
                .fixedSize()
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

    // MARK: - Custom analysis (streamed)

    @ViewBuilder
    private var customAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Свой анализ")
                    .font(.headline)
                Spacer()
                if coordinator.isStreaming && !coordinator.streamingCustomTitle.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Генерируем «\(coordinator.streamingCustomTitle)»…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Название (опционально)", text: $customAnalysisTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                TextField(
                    "Например: оцени стрессоустойчивость кандидата",
                    text: $customAnalysisPrompt
                )
                .textFieldStyle(.roundedBorder)
                Button {
                    coordinator.runCustomAnalysis(
                        title:  customAnalysisTitle,
                        prompt: customAnalysisPrompt
                    )
                    customAnalysisPrompt = ""
                    customAnalysisTitle = ""
                } label: {
                    Image(systemName: "play.fill")
                }
                .disabled(coordinator.isStreaming || customAnalysisPrompt.isEmpty)
            }

            // Live streaming output
            if coordinator.isStreaming && !coordinator.streamingCustomTitle.isEmpty {
                ScrollView {
                    Text(markdown: coordinator.streamingCustomReply)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .padding(10)
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Saved custom analyses
            if let saved = coordinator.currentSession?.customAnalyses,
               !saved.isEmpty {
                ForEach(saved) { analysis in
                    customAnalysisCard(analysis)
                }
            }
        }
        .padding(.top, 16)
    }

    private func customAnalysisCard(_ a: CustomAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(a.title).font(.headline)
                Spacer()
                Text("\(a.provider.providerID) · \(a.provider.model)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button {
                    coordinator.deleteCustomAnalysis(a.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Удалить")
            }
            Text("Промпт: \(a.prompt)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Divider()
            Text(markdown: a.result)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .cardStyle()
    }

    // MARK: - Chat panel

    @ViewBuilder
    private var chatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Чат по интервью")
                    .font(.headline)
                Spacer()
                if !coordinator.chatHistory.isEmpty {
                    Button("Очистить") {
                        coordinator.resetChat()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if coordinator.chatHistory.isEmpty && coordinator.streamingChatReply.isEmpty {
                Text("Спроси что угодно про это интервью — например: «Как кандидат отвечал про работу в команде?»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.gray.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(coordinator.chatHistory) { msg in
                        chatBubble(msg)
                    }
                    if coordinator.isStreaming && !coordinator.streamingChatReply.isEmpty {
                        chatBubble(ChatMessage(
                            role: .assistant,
                            content: coordinator.streamingChatReply
                        ))
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Ваш вопрос…", text: $chatDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendChat)

                Button {
                    sendChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(coordinator.isStreaming || chatDraft.isEmpty)

                if coordinator.isStreaming && !coordinator.streamingChatReply.isEmpty {
                    Button {
                        coordinator.cancelStreaming()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Прервать")
                }
            }
        }
        .padding(.top, 16)
    }

    private func sendChat() {
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        coordinator.sendChatMessage(text)
        chatDraft = ""
    }

    private func chatBubble(_ msg: ChatMessage) -> some View {
        HStack {
            if msg.role == .assistant { Spacer(minLength: 30) }
            VStack(alignment: .leading, spacing: 4) {
                Text(msg.role == .user ? "Ты" : "Ассистент")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(markdown: msg.content)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(msg.role == .user ? Color.blue.opacity(0.12) : Color.gray.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if msg.role == .user { Spacer(minLength: 30) }
        }
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
            Text(markdown: s.overallImpression)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if !s.strengths.isEmpty {
                Text("Сильные стороны").font(.subheadline.bold())
                ForEach(Array(s.strengths.enumerated()), id: \.offset) { _, line in
                    Text(markdown: "• \(line)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !s.concerns.isEmpty {
                Text("Опасения").font(.subheadline.bold())
                ForEach(Array(s.concerns.enumerated()), id: \.offset) { _, line in
                    Text(markdown: "• \(line)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !s.highlights.isEmpty {
                let showSpeaker = coordinator.currentSession?.transcript?.isMultiSpeaker ?? true
                Text("Интересные моменты").font(.subheadline.bold())
                ForEach(Array(s.highlights.enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(highlightHeader(h, showSpeaker: showSpeaker))
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text("«\(h.quote)»").italic()
                            .fixedSize(horizontal: false, vertical: true)
                        Text(markdown: h.why).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
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
                    Text(markdown: "• \(line)")
                        .fixedSize(horizontal: false, vertical: true)
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
            Text(markdown: r.rationale)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text(markdown: q.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let r = q.rationale, !r.isEmpty {
                        Text(markdown: r).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

    private func highlightHeader(_ h: Summary.Highlight, showSpeaker: Bool) -> String {
        let mins = Int(h.timestamp) / 60
        let secs = Int(h.timestamp) % 60
        let ts = String(format: "%02d:%02d", mins, secs)
        return showSpeaker ? "\(ts) — \(h.speaker.localizedName)" : ts
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

    private var welcomeBanner: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.blue.gradient)
            Text("Привет 👋")
                .font(.title2.bold())
            Text("Запиши своё первое интервью — нажми «Начать запись» внизу, или перетащи готовый аудио/видео файл в это окно.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            HStack(spacing: 20) {
                stepHint("1.", "Записать", "Mic + системный звук")
                stepHint("2.", "Транскрибировать", "WhisperKit на ANE")
                stepHint("3.", "Анализ", "DeepSeek / Ollama")
            }
            .padding(.top, 8)

            Text("⌘N — новое интервью · ⌘, — настройки")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func stepHint(_ num: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(num).font(.caption.bold()).foregroundStyle(.blue)
            Text(title).font(.subheadline.bold())
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 110)
    }

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

    @ViewBuilder
    private func sessionCard(_ session: Session) -> some View {
        SessionCardView(
            session: session,
            isReady: coordinator.state == .ready,
            onReset: coordinator.reset,
            onSave:  coordinator.updateCurrentMetadata
        )
    }

    private func transcriptList(_ segments: [TranscriptSegment]) -> some View {
        let showSpeakers = coordinator.currentSession?.transcript?.isMultiSpeaker ?? true
        let isLong = segments.count > 5
        let shown  = (!isLong || transcriptExpanded) ? segments : Array(segments.prefix(3))

        return VStack(alignment: .leading, spacing: 10) {
            audioPlayerBar
            HStack {
                Button {
                    if isLong { transcriptExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if isLong {
                            Image(systemName: transcriptExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Транскрипт (\(segments.count) сегментов)")
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isLong)

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
                        coordinator.retranscribe()
                    }
                    .disabled(coordinator.transcribingSessionID == coordinator.currentSession?.id)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ForEach(shown) { seg in
                SegmentRow(
                    segment: seg,
                    showSpeaker: showSpeakers,
                    isPlayingThis: isPlayingSegment(seg),
                    onPlay: { playSegment(seg) }
                )
            }

            if isLong && !transcriptExpanded {
                Button {
                    transcriptExpanded = true
                } label: {
                    Text("Показать все \(segments.count) сегментов")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Whether the currently playing position is within this segment.
    private func isPlayingSegment(_ seg: TranscriptSegment) -> Bool {
        guard audioPlayer.isPlaying,
              audioPlayer.currentSessionID == coordinator.currentSession?.id else {
            return false
        }
        return audioPlayer.currentTime >= seg.startTime &&
               audioPlayer.currentTime <= seg.endTime
    }

    private func playSegment(_ seg: TranscriptSegment) {
        guard let session = coordinator.currentSession else { return }
        Task { await audioPlayer.play(at: seg.startTime, session: session, store: sessionStore) }
    }

    // MARK: - Audio player bar

    @ViewBuilder
    private var audioPlayerBar: some View {
        if let session = coordinator.currentSession,
           session.transcript != nil {
            HStack(spacing: 10) {
                Button {
                    if audioPlayer.currentSessionID == session.id {
                        audioPlayer.togglePlayPause()
                    } else {
                        Task { await audioPlayer.play(at: 0, session: session, store: sessionStore) }
                    }
                } label: {
                    Image(systemName: audioPlayer.isPlaying &&
                          audioPlayer.currentSessionID == session.id
                          ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Воспроизвести запись")

                Text(playerTimestamp)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { audioPlayer.currentTime },
                        set: { audioPlayer.seek(to: $0) }
                    ),
                    in: 0...max(audioPlayer.duration, session.metadata.duration, 1)
                )
                .disabled(audioPlayer.currentSessionID != session.id)
            }
            .padding(8)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var playerTimestamp: String {
        let current = Int(audioPlayer.currentTime)
        let total   = Int(coordinator.currentSession?.metadata.duration ?? 0)
        return String(format: "%02d:%02d / %02d:%02d",
                      current / 60, current % 60,
                      total / 60,   total % 60)
    }

    // MARK: - Computed

    private var isCurrentSessionTranscribing: Bool {
        guard let id = coordinator.currentSession?.id else { return false }
        return coordinator.transcribingSessionID == id
    }

    private var isCurrentSessionQueued: Bool {
        guard let id = coordinator.currentSession?.id else { return false }
        return coordinator.queuedTranscriptionIDs.contains(id)
    }

    private var stateLabel: String {
        if isCurrentSessionTranscribing { return "Транскрибируем эту сессию…" }
        if isCurrentSessionQueued       { return "В очереди на транскрипцию…" }
        switch coordinator.state {
        case .idle:           return "Готов к записи"
        case .preparing:      return "Запрашиваем доступ…"
        case .recording:      return "Идёт запись"
        case .stopping:       return "Сохраняем…"
        case .transcribing:   return "Транскрибируем…"
        case .ready:          return "Готово"
        case .failed(let m):  return "Ошибка: \(m)"
        }
    }

    private var stateColor: Color {
        if isCurrentSessionTranscribing || isCurrentSessionQueued { return .orange }
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
            // Stage label
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(transcriptionStageLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private var transcriptionStageLabel: String {
        switch coordinator.transcriptionServiceState {
        case .loadingModel:
            let secs = coordinator.modelLoadingSeconds
            let mins = secs / 60
            let s    = secs % 60
            let elapsed = mins > 0
                ? String(format: "%d мин %02d сек", mins, s)
                : "\(secs) сек"
            return "Загружаем модель Whisper… \(elapsed). Первый запуск может занять до 10 мин — ANE компилирует под твоё железо."
        case .transcribing:
            return "Транскрибируем…"
        case .failed(let m):
            return "Ошибка: \(m)"
        case .idle, .ready:
            return "Ставим в очередь…"
        }
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
    var showSpeaker: Bool = true
    var isPlayingThis: Bool = false
    var onPlay: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: isPlayingThis ? "speaker.wave.2.fill" : "play.circle")
                    .foregroundStyle(isPlayingThis ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Воспроизвести с этого момента")

            Text(timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            if showSpeaker {
                Text(segment.speaker.localizedName)
                    .font(.caption.bold())
                    .foregroundStyle(segment.speaker == .interviewer ? .blue : .green)
                    .frame(width: 90, alignment: .leading)
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(isPlayingThis ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
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

// MARK: - Editable session card

private struct SessionCardView: View {
    let session: Session
    let isReady: Bool
    let onReset: () -> Void
    let onSave:  (_ candidateName: String?, _ position: String?) -> Void

    @State private var isEditing = false
    @State private var nameDraft: String = ""
    @State private var positionDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Сессия")
                    .font(.headline)
                Spacer()
                if isEditing {
                    Button("Сохранить") {
                        onSave(nameDraft, positionDraft)
                        isEditing = false
                    }
                    .buttonStyle(.link)
                    Button("Отмена") {
                        isEditing = false
                        loadDrafts()
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                } else {
                    Button {
                        loadDrafts()
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Изменить имя и позицию")

                    if isReady {
                        Button("Новая запись", action: onReset)
                            .buttonStyle(.link)
                    }
                }
            }

            if isEditing {
                TextField("Имя кандидата", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                TextField("Позиция", text: $positionDraft)
                    .textFieldStyle(.roundedBorder)
            } else {
                if let name = session.metadata.candidateName, !name.isEmpty {
                    Text("Кандидат: \(name)")
                } else {
                    Text("Кандидат: (без имени)").foregroundStyle(.secondary)
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear(perform: loadDrafts)
    }

    private func loadDrafts() {
        nameDraft     = session.metadata.candidateName ?? ""
        positionDraft = session.metadata.position      ?? ""
    }
}

#Preview {
    ContentView(
        providerSettings: ProviderSettings(),
        templates: NotesTemplateStore()
    )
}
