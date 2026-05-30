//
//  InterviewAssistantApp.swift
//  InterviewAssistant
//

import SwiftUI

@main
struct InterviewAssistantApp: App {

    @StateObject private var providerSettings = ProviderSettings()
    @StateObject private var whisperSettings  = WhisperSettings()
    @StateObject private var templates        = NotesTemplateStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                providerSettings: providerSettings,
                templates:        templates
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новое интервью") {
                    NotificationCenter.default.post(name: .newInterviewShortcut, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        Settings {
            SettingsView(
                settings:  providerSettings,
                whisper:   whisperSettings,
                templates: templates
            )
        }
    }
}

extension Notification.Name {
    static let newInterviewShortcut = Notification.Name("newInterviewShortcut")
}
