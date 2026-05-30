//
//  SettingsView.swift
//  InterviewAssistant
//
//  Lets the user pick an LLM provider and supply credentials.
//

import SwiftUI

struct SettingsView: View {

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
                Button(action: runTest) {
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
        .frame(minWidth: 460, minHeight: 380)
        .onAppear {
            apiKeyDraft = settings.apiKey
        }
    }

    // MARK: - Actions

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
