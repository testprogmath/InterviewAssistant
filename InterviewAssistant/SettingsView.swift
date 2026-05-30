//
//  SettingsView.swift
//  InterviewAssistant
//
//  Two tabs:
//    1. Provider — pick an LLM and supply API key
//    2. Templates — manage reusable notes-templates
//

import SwiftUI

struct SettingsView: View {

    @ObservedObject var settings: ProviderSettings
    @ObservedObject var whisper: WhisperSettings
    @ObservedObject var templates: NotesTemplateStore

    var body: some View {
        TabView {
            ProviderSettingsTab(settings: settings)
                .tabItem { Label("LLM провайдер", systemImage: "brain") }
                .padding()

            WhisperSettingsTab(settings: whisper)
                .tabItem { Label("Транскрипция", systemImage: "waveform") }
                .padding()

            TemplatesSettingsTab(templates: templates)
                .tabItem { Label("Шаблоны заметок", systemImage: "doc.text") }
                .padding()
        }
        .frame(minWidth: 580, minHeight: 460)
    }
}

// MARK: - Whisper tab

private struct WhisperSettingsTab: View {
    @ObservedObject var settings: WhisperSettings
    @State private var initialModelID: String?

    var body: some View {
        Form {
            Section("Модель Whisper") {
                Picker("Модель", selection: $settings.modelID) {
                    ForEach(WhisperSettings.allOptions) { opt in
                        Text(opt.displayName).tag(opt.id)
                    }
                }
                if let opt = WhisperSettings.allOptions.first(where: { $0.id == settings.modelID }) {
                    Text(opt.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let initial = initialModelID, initial != settings.modelID {
                Section {
                    Label(
                        "Перезапусти приложение, чтобы новая модель загрузилась. Текущая модель остаётся активной до перезапуска.",
                        systemImage: "arrow.clockwise"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Замечания") {
                Text("• Модель скачивается один раз при первом использовании (200 МБ–1.5 ГБ)\n• Первая компиляция под Apple Neural Engine медленная, потом результат кешируется\n• Качество русского: Large > Medium > Small")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { if initialModelID == nil { initialModelID = settings.modelID } }
    }
}

// MARK: - Provider tab

private struct ProviderSettingsTab: View {

    @ObservedObject var settings: ProviderSettings

    @State private var apiKeyDraft: String = ""
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case running
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section("Провайдер LLM") {
                Picker("Провайдер", selection: $settings.choice) {
                    ForEach(ProviderSettings.Choice.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .onChange(of: settings.choice) { _, newChoice in
                    settings.model = newChoice.defaultModel
                    apiKeyDraft = settings.apiKey
                    testResult = nil
                }

                TextField("Модель", text: $settings.model)
            }

            if !settings.choice.needsAPIKey {
                Section("Ollama") {
                    Text("Запусти **`ollama serve`** в терминале. Установи модель командой **`ollama pull \(settings.model)`**, если её ещё нет.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.choice.needsAPIKey {
                Section("API-ключ") {
                    SecureField("Введите API-ключ", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    HStack {
                        Button("Сохранить") { saveKey() }
                            .disabled(apiKeyDraft.isEmpty)
                        Button("Очистить") {
                            apiKeyDraft = ""
                            settings.apiKey = ""
                            testResult = nil
                        }
                        .foregroundStyle(.red)
                        .disabled(settings.apiKey.isEmpty)
                    }
                    Text("Ключ хранится в системном Keychain и не попадает в репозиторий.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Проверка соединения") {
                Button {
                    runTest()
                } label: {
                    HStack {
                        Image(systemName: "wifi")
                        Text("Проверить соединение")
                    }
                }
                .disabled(isTestDisabled)

                if let result = testResult {
                    switch result {
                    case .running:
                        HStack { ProgressView(); Text("Проверяем…") }
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { apiKeyDraft = settings.apiKey }
    }

    private func saveKey() {
        settings.apiKey = apiKeyDraft
        testResult = nil
    }

    private var isTestDisabled: Bool {
        if testResult == .running { return true }
        if settings.choice.needsAPIKey && settings.apiKey.isEmpty { return true }
        return false
    }

    private func runTest() {
        testResult = .running
        Task {
            guard let provider = settings.currentProvider() else {
                testResult = .failure("Провайдер не сконфигурирован")
                return
            }
            do {
                let echo = try await provider.testConnection()
                testResult = .success(echo)
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Templates tab

private struct TemplatesSettingsTab: View {

    @ObservedObject var templates: NotesTemplateStore
    @State private var selectedID: UUID?

    var body: some View {
        HSplitView {
            // ── Left: list of templates ────────────────────────────────
            VStack(spacing: 0) {
                HStack {
                    Text("Шаблоны")
                        .font(.headline)
                    Spacer()
                    Button {
                        templates.add(
                            name: "Новый шаблон",
                            promptTemplate: "",
                            description: ""
                        )
                        selectedID = templates.templates.last?.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Создать новый шаблон")
                }
                .padding(10)

                Divider()

                if templates.templates.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Пока пусто.\nНажми + чтобы создать первый шаблон.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxHeight: .infinity)
                } else {
                    List(selection: $selectedID) {
                        ForEach(templates.templates) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.body)
                                if !t.description.isEmpty {
                                    Text(t.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .tag(t.id)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 320)

            // ── Right: editor ──────────────────────────────────────────
            if let id = selectedID,
               let binding = bindingForTemplate(id: id) {
                TemplateEditor(template: binding, onDelete: {
                    templates.delete(id)
                    selectedID = nil
                })
                .frame(minWidth: 320)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Выбери шаблон слева или создай новый")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func bindingForTemplate(id: UUID) -> Binding<NotesTemplate>? {
        guard let idx = templates.templates.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { templates.templates[idx] },
            set: { templates.update($0) }
        )
    }
}

private struct TemplateEditor: View {
    @Binding var template: NotesTemplate
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Название").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                }
                TextField("Название", text: $template.name)
                    .textFieldStyle(.roundedBorder)

                Text("Описание (необязательно)")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Например: формат для технических интервью", text: $template.description)
                    .textFieldStyle(.roundedBorder)

                Text("Шаблон / пример")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Вставь сюда пример заметок или укажи структуру, которой должна следовать модель.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $template.promptTemplate)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .padding(6)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding()
        }
    }
}
