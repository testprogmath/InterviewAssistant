//
//  NotesTemplateStore.swift
//  InterviewAssistant
//
//  Persists the user's reusable notes templates in a single JSON file
//  inside the app's Application Support directory.
//

import Foundation
import Combine
import OSLog

@MainActor
final class NotesTemplateStore: ObservableObject {

    @Published private(set) var templates: [NotesTemplate] = []

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let log = Logger(subsystem: "com.anna.interview", category: "Templates")

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.fileURL = appSupport.appendingPathComponent("notes_templates.json")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    // MARK: - CRUD

    func add(name: String, promptTemplate: String, description: String = "") {
        let t = NotesTemplate(
            name:           name,
            promptTemplate: promptTemplate,
            description:    description
        )
        templates.append(t)
        save()
    }

    func update(_ template: NotesTemplate) {
        guard let idx = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[idx] = template
        save()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            templates = try decoder.decode([NotesTemplate].self, from: data)
            log.info("Loaded \(self.templates.count) templates")
        } catch {
            log.error("Could not load templates: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(templates)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("Could not save templates: \(error.localizedDescription)")
        }
    }
}
