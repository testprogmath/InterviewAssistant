//
//  ProviderSettings.swift
//  InterviewAssistant
//
//  Stores the user's choice of LLM provider and API key.
//
//  • Provider id + model name live in UserDefaults (not secret).
//  • API keys live in the macOS Keychain, indexed by provider id.
//
//  The Settings UI talks to this object; the rest of the app asks it
//  for a ready-to-use `AnalysisProvider` via `currentProvider()`.
//

import Foundation
import Security
import Combine
import OSLog

@MainActor
final class ProviderSettings: ObservableObject {

    enum Choice: String, CaseIterable, Identifiable {
        case deepseek
        case openai
        case ollama

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .deepseek: return "DeepSeek"
            case .openai:   return "OpenAI"
            case .ollama:   return "Ollama (локально)"
            }
        }

        var defaultModel: String {
            switch self {
            case .deepseek: return "deepseek-chat"
            case .openai:   return "gpt-5-mini"
            case .ollama:   return "qwen3:8b"
            }
        }

        var needsAPIKey: Bool {
            self != .ollama
        }
    }

    // MARK: - Published state

    @Published var choice: Choice {
        didSet { defaults.set(choice.rawValue, forKey: Self.keyChoice) }
    }
    @Published var model: String {
        didSet { defaults.set(model, forKey: Self.keyModel) }
    }

    // MARK: - API key (Keychain-backed)

    /// Read the current provider's API key from the Keychain.
    /// Whitespace and newlines are stripped on both read and write so a
    /// stray space copied from a dashboard doesn't break authentication.
    var apiKey: String {
        get {
            let raw = Keychain.read(service: keychainService, account: choice.rawValue) ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Keychain.delete(service: keychainService, account: choice.rawValue)
            } else {
                Keychain.write(trimmed, service: keychainService, account: choice.rawValue)
            }
            objectWillChange.send()
        }
    }

    // MARK: - Private storage

    private let defaults: UserDefaults
    private let keychainService = "com.anna.interview.providers"
    private static let keyChoice = "provider.choice"
    private static let keyModel  = "provider.model"

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let saved = defaults.string(forKey: Self.keyChoice).flatMap(Choice.init(rawValue:))
        let initial = saved ?? .deepseek
        self.choice = initial
        self.model  = defaults.string(forKey: Self.keyModel) ?? initial.defaultModel
    }

    // MARK: - Factory

    /// Build a fresh AnalysisProvider for the currently selected config.
    /// Returns nil if the user hasn't filled in an API key where required.
    func currentProvider() -> AnalysisProvider? {
        switch choice {
        case .deepseek:
            guard !apiKey.isEmpty else { return nil }
            return OpenAICompatibleProvider.deepSeek(apiKey: apiKey, model: model)

        case .openai:
            guard !apiKey.isEmpty else { return nil }
            return OpenAICompatibleProvider.openAI(apiKey: apiKey, model: model)

        case .ollama:
            // Implemented in a follow-up file; nil for now so the UI can
            // still build.
            return nil
        }
    }
}

// MARK: - Keychain helper

private enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass            as String: kSecClassGenericPassword,
            kSecAttrService      as String: service,
            kSecAttrAccount      as String: account,
            kSecReturnData       as String: true,
            kSecMatchLimit       as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    @discardableResult
    static func write(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
