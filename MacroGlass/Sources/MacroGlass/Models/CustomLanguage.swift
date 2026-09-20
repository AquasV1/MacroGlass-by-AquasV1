import Foundation
import Combine

// MARK: - Identity
//
// Built-ins and user-added languages share one namespace so a library can
// say which languages it belongs to without caring where they came from.

enum LanguageID {
    static func builtIn(_ language: ScriptLanguage) -> String { language.rawValue }
    static func custom(_ id: UUID) -> String { "custom:\(id.uuidString)" }
}

// MARK: - A language the user added

/// Anything with an interpreter that takes a file path can be added here:
/// Ruby, Perl, PHP, Deno, Fish, a wrapper script of your own — MacroGlass
/// writes the editor's contents to a temp file and hands it over.
struct CustomLanguage: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// An absolute path, or a bare command name resolved on PATH, in
    /// Homebrew, or through a login shell.
    var interpreter: String
    /// `{script}` is replaced with the temp file's path. If the placeholder
    /// appears nowhere, the path is appended as the last argument.
    var arguments: [String] = [CustomLanguage.scriptPlaceholder]
    var fileExtension: String = "txt"
    var commentPrefix: String = "#"
    var starterTemplate: String = ""

    static let scriptPlaceholder = "{script}"

    /// The arguments string as one editable line, which is how Settings
    /// shows it. Quoting is deliberately not supported — arguments with
    /// spaces in them are vanishingly rare here and splitting on
    /// whitespace keeps the field honest about what it does.
    var argumentLine: String {
        get { arguments.joined(separator: " ") }
        set {
            arguments = newValue
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
        }
    }

    func resolvedArguments(scriptURL: URL) -> [String] {
        var resolved = arguments.map {
            $0.replacingOccurrences(of: Self.scriptPlaceholder, with: scriptURL.path)
        }
        if !arguments.contains(where: { $0.contains(Self.scriptPlaceholder) }) {
            resolved.append(scriptURL.path)
        }
        return resolved
    }

    /// One-tap starting points in Settings → Languages, so adding Ruby
    /// doesn't mean remembering what its interpreter is called.
    static let presets: [CustomLanguage] = [
        CustomLanguage(
            name: "Ruby", interpreter: "ruby", fileExtension: "rb",
            commentPrefix: "#", starterTemplate: "puts \"Hello from MacroGlass\"\n"
        ),
        CustomLanguage(
            name: "Perl", interpreter: "perl", fileExtension: "pl",
            commentPrefix: "#", starterTemplate: "print \"Hello from MacroGlass\\n\";\n"
        ),
        CustomLanguage(
            name: "PHP", interpreter: "php", fileExtension: "php",
            commentPrefix: "//", starterTemplate: "<?php\necho \"Hello from MacroGlass\\n\";\n"
        ),
        CustomLanguage(
            name: "Lua", interpreter: "lua", fileExtension: "lua",
            commentPrefix: "--", starterTemplate: "print(\"Hello from MacroGlass\")\n"
        ),
        CustomLanguage(
            name: "Deno", interpreter: "deno", arguments: ["run", "-A", CustomLanguage.scriptPlaceholder],
            fileExtension: "ts", commentPrefix: "//",
            starterTemplate: "console.log(\"Hello from MacroGlass\")\n"
        ),
        CustomLanguage(
            name: "Swift", interpreter: "swift", fileExtension: "swift",
            commentPrefix: "//", starterTemplate: "print(\"Hello from MacroGlass\")\n"
        ),
        CustomLanguage(
            name: "Fish", interpreter: "fish", fileExtension: "fish",
            commentPrefix: "#", starterTemplate: "echo \"Hello from MacroGlass\"\n"
        ),
        CustomLanguage(
            name: "Go", interpreter: "go", arguments: ["run", CustomLanguage.scriptPlaceholder],
            fileExtension: "go", commentPrefix: "//",
            starterTemplate: "package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(\"Hello from MacroGlass\")\n}\n"
        )
    ]
}

// MARK: - A library

/// A chunk of code pasted in front of your script before it runs — helper
/// functions, constants, an import block. Libraries that name no languages
/// apply to everything; otherwise only to the ones listed.
struct ScriptLibrary: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var content: String
    var languageIDs: [String] = []
    var isEnabled: Bool = true
    /// Set when the library was imported from a file, so it can be
    /// refreshed from disk later.
    var sourcePath: String = ""

    func applies(to languageID: String) -> Bool {
        isEnabled && (languageIDs.isEmpty || languageIDs.contains(languageID))
    }

    var scopeDescription: String {
        languageIDs.isEmpty ? "every language" : "\(languageIDs.count) language\(languageIDs.count == 1 ? "" : "s")"
    }

    var lineCount: Int {
        content.isEmpty ? 0 : content.components(separatedBy: "\n").count
    }
}

// MARK: - One entry in the Language menu

/// Flattens built-ins and user-added languages into a single list the
/// picker, the runner and the file-open sheet can all work from.
struct LanguageChoice: Identifiable, Hashable {
    var id: String
    var displayName: String
    var fileExtension: String
    var commentPrefix: String
    var starterTemplate: String
    var builtIn: ScriptLanguage?
    var custom: CustomLanguage?

    var isCustom: Bool { custom != nil }

    init(_ language: ScriptLanguage) {
        id = LanguageID.builtIn(language)
        displayName = language.displayName
        fileExtension = language.fileExtension
        commentPrefix = language.commentPrefix
        starterTemplate = language.starterTemplate
        builtIn = language
        custom = nil
    }

    init(_ language: CustomLanguage) {
        id = LanguageID.custom(language.id)
        displayName = language.name
        fileExtension = language.fileExtension
        commentPrefix = language.commentPrefix
        starterTemplate = language.starterTemplate
        builtIn = nil
        custom = language
    }
}

// MARK: - Store

/// Holds the user's own languages and libraries, mirrored to JSON next to
/// macros.json. Main-thread only, like MacroStore.
final class LanguageRegistry: ObservableObject {
    @Published var languages: [CustomLanguage] = [] { didSet { persist() } }
    @Published var libraries: [ScriptLibrary] = [] { didSet { persist() } }

    private let url: URL
    private var isLoading = false

    private struct Payload: Codable {
        var languages: [CustomLanguage]
        var libraries: [ScriptLibrary]
    }

    init() {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacroGlass", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        url = supportDir.appendingPathComponent("languages.json")
        load()
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        languages = payload.languages
        libraries = payload.libraries
    }

    private func persist() {
        guard !isLoading else { return }
        let payload = Payload(languages: languages, libraries: libraries)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Choices

    var choices: [LanguageChoice] {
        builtInChoices + customChoices
    }

    var builtInChoices: [LanguageChoice] {
        ScriptLanguage.allCases.map { LanguageChoice($0) }
    }

    var customChoices: [LanguageChoice] {
        languages.map { LanguageChoice($0) }
    }

    func choice(id: String) -> LanguageChoice? {
        choices.first { $0.id == id }
    }

    /// Rebuilds the choice a saved script was written in.
    func choice(for script: SavedScript) -> LanguageChoice {
        if let customID = script.customLanguageID,
           let match = choices.first(where: { $0.id == customID }) {
            return match
        }
        return LanguageChoice(script.language)
    }

    /// Custom languages win when their extension collides with a built-in,
    /// so adding "Lua" and opening a .lua file picks yours rather than Luau.
    func choice(forFileExtension ext: String) -> LanguageChoice? {
        let lowered = ext.lowercased()
        if let custom = languages.first(where: { $0.fileExtension.lowercased() == lowered }) {
            return LanguageChoice(custom)
        }
        guard let builtIn = ScriptLanguage.forFileExtension(lowered) else { return nil }
        return LanguageChoice(builtIn)
    }

    var openableExtensions: [String] {
        var set = Set(["sh", "zsh", "bash", "py", "js", "mjs", "applescript", "scpt", "luau", "lua", "ahk", "txt"])
        for language in languages { set.insert(language.fileExtension.lowercased()) }
        return set.sorted()
    }

    // MARK: Editing

    func upsert(_ language: CustomLanguage) {
        if let index = languages.firstIndex(where: { $0.id == language.id }) {
            languages[index] = language
        } else {
            languages.append(language)
        }
    }

    func delete(_ language: CustomLanguage) {
        let removedID = LanguageID.custom(language.id)
        languages.removeAll { $0.id == language.id }
        // Don't leave libraries scoped to a language that's gone.
        for index in libraries.indices {
            libraries[index].languageIDs.removeAll { $0 == removedID }
        }
    }

    func upsert(_ library: ScriptLibrary) {
        if let index = libraries.firstIndex(where: { $0.id == library.id }) {
            libraries[index] = library
        } else {
            libraries.append(library)
        }
    }

    func delete(_ library: ScriptLibrary) {
        libraries.removeAll { $0.id == library.id }
    }

    func toggle(_ library: ScriptLibrary) {
        guard let index = libraries.firstIndex(where: { $0.id == library.id }) else { return }
        libraries[index].isEnabled.toggle()
    }

    func libraries(for languageID: String) -> [ScriptLibrary] {
        libraries.filter { $0.applies(to: languageID) }
    }

    /// Re-reads every library that came from a file on disk.
    @discardableResult
    func refreshImportedLibraries() -> Int {
        var refreshed = 0
        for index in libraries.indices where !libraries[index].sourcePath.isEmpty {
            let path = libraries[index].sourcePath
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if libraries[index].content != text {
                libraries[index].content = text
                refreshed += 1
            }
        }
        return refreshed
    }
}
