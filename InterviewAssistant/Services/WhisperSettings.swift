//
//  WhisperSettings.swift
//  InterviewAssistant
//
//  User-selectable Whisper model. Changing the model requires an app
//  restart (the loaded WhisperKit instance is cached) — the Settings UI
//  warns about that.
//

import Foundation

@MainActor
final class WhisperSettings: ObservableObject {

    struct ModelOption: Identifiable, Hashable {
        let id:           String      // the WhisperKit model identifier
        let displayName:  String      // shown in the picker
        let description:  String      // hint about speed/quality trade-off
    }

    static let allOptions: [ModelOption] = [
        .init(
            id:          "openai_whisper-small",
            displayName: "Small",
            description: "~250 МБ. Очень быстрая компиляция (~30 сек). Приемлемое качество русского. Рекомендуется для слабого железа (MacBook Air)."
        ),
        .init(
            id:          "openai_whisper-medium",
            displayName: "Medium ⭐",
            description: "~1.5 ГБ. Быстрая компиляция (~1 мин). Хорошее качество русского. Баланс для большинства задач."
        ),
        .init(
            id:          "openai_whisper-large-v3-v20240930_turbo",
            displayName: "Large v3 Turbo",
            description: "~1.5 ГБ. Долгая компиляция (5-10 мин). Лучшее качество русского. Для топового железа (M-Pro/M-Max)."
        ),
        .init(
            id:          "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Large v3 Turbo (int4)",
            description: "~632 МБ. Очень долгая компиляция (10+ мин). Качество близко к Large. Меньше памяти."
        ),
    ]

    @Published var modelID: String {
        didSet { defaults.set(modelID, forKey: Self.key) }
    }

    private let defaults: UserDefaults
    private static let key = "whisper.model"
    private static let defaultModelID = "openai_whisper-medium"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.modelID = defaults.string(forKey: Self.key) ?? Self.defaultModelID
    }

    /// Current model selection, snapshot for handing to TranscriptionService.
    static func currentModelID(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: key) ?? defaultModelID
    }
}
