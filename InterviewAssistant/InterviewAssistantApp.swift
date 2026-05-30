//
//  InterviewAssistantApp.swift
//  InterviewAssistant
//

import SwiftUI

@main
struct InterviewAssistantApp: App {

    // Provider settings live for the whole app lifetime — both the main
    // window and the Settings scene observe the same instance.
    @StateObject private var providerSettings = ProviderSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(providerSettings: providerSettings)
        }

        Settings {
            SettingsView(settings: providerSettings)
        }
    }
}
