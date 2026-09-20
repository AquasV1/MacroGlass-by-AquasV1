import Foundation
import Combine

/// Holds saved macros and scripts in memory and mirrors them to JSON files
/// under ~/Library/Application Support/MacroGlass/. Only ever touched from
/// the main thread (SwiftUI views), so it carries no actor annotation —
/// that keeps view helper methods free to call it synchronously.
final class MacroStore: ObservableObject {
    @Published var macros: [Macro] = [] { didSet { saveMacros() } }
    @Published var scripts: [SavedScript] = [] { didSet { saveScripts() } }

    private let macrosURL: URL
    private let scriptsURL: URL
    private var isLoading = false

    init() {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacroGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        macrosURL = supportDir.appendingPathComponent("macros.json")
        scriptsURL = supportDir.appendingPathComponent("scripts.json")
        load()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        if let data = try? Data(contentsOf: macrosURL),
           let decoded = try? JSONDecoder().decode([Macro].self, from: data) {
            macros = decoded
        }
        if let data = try? Data(contentsOf: scriptsURL),
           let decoded = try? JSONDecoder().decode([SavedScript].self, from: data) {
            scripts = decoded
        }
    }

    private func saveMacros() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(macros) {
            try? data.write(to: macrosURL, options: .atomic)
        }
    }

    private func saveScripts() {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(scripts) {
            try? data.write(to: scriptsURL, options: .atomic)
        }
    }

    // MARK: Macros

    func addMacro(_ macro: Macro) { macros.insert(macro, at: 0) }

    func deleteMacro(_ macro: Macro) { macros.removeAll { $0.id == macro.id } }

    func updateMacro(_ macro: Macro) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        macros[index] = macro
    }

    func rename(_ macro: Macro, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        macros[index].name = trimmed
    }

    /// A copy never inherits the original's hotkey — two macros on one
    /// combination would just mean whichever is found first wins.
    @discardableResult
    func duplicate(_ macro: Macro) -> Macro {
        var copy = macro
        copy.id = UUID()
        copy.name = uniqueName(basedOn: macro.name)
        copy.createdAt = Date()
        copy.hotkey = nil
        if let index = macros.firstIndex(where: { $0.id == macro.id }) {
            macros.insert(copy, at: index + 1)
        } else {
            macros.insert(copy, at: 0)
        }
        return copy
    }

    func setHotkey(_ hotkey: MacroHotkey?, for macro: Macro) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        // One combination, one macro.
        if let hotkey {
            for other in macros.indices where other != index {
                if macros[other].hotkey == hotkey { macros[other].hotkey = nil }
            }
        }
        macros[index].hotkey = hotkey
    }

    func moveMacro(_ macro: Macro, by offset: Int) {
        guard let index = macros.firstIndex(where: { $0.id == macro.id }) else { return }
        let target = index + offset
        guard macros.indices.contains(target) else { return }
        macros.swapAt(index, target)
    }

    private func uniqueName(basedOn name: String) -> String {
        var candidate = name + " copy"
        var counter = 2
        while macros.contains(where: { $0.name == candidate }) {
            candidate = "\(name) copy \(counter)"
            counter += 1
        }
        return candidate
    }

    // MARK: Scripts

    func upsertScript(_ script: SavedScript) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
        } else {
            scripts.insert(script, at: 0)
        }
    }

    func deleteScript(_ script: SavedScript) { scripts.removeAll { $0.id == script.id } }

    func renameScript(_ script: SavedScript, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index].name = trimmed
    }

    // MARK: Moving macros in and out

    func exportData(for macros: [Macro]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(macros)
    }

    /// Accepts both a single macro and an array of them, since that's what
    /// people actually end up with when they share files around. Imported
    /// macros always get fresh IDs so importing your own export twice gives
    /// you two macros rather than a silent no-op.
    @discardableResult
    func importMacros(from data: Data) throws -> Int {
        let decoder = JSONDecoder()
        var incoming: [Macro]
        if let many = try? decoder.decode([Macro].self, from: data) {
            incoming = many
        } else {
            incoming = [try decoder.decode(Macro.self, from: data)]
        }

        for var macro in incoming.reversed() {
            macro.id = UUID()
            macro.hotkey = nil
            if macros.contains(where: { $0.name == macro.name }) {
                macro.name = uniqueName(basedOn: macro.name)
            }
            macros.insert(macro, at: 0)
        }
        return incoming.count
    }
}
