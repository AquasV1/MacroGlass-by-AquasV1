import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScriptView: View {
    @ObservedObject var store: MacroStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var registry: LanguageRegistry

    @State private var choiceID: String = LanguageID.builtIn(.bash)
    @State private var content = ScriptLanguage.bash.starterTemplate
    @State private var output = ""
    @State private var errorOutput = ""
    @State private var exitCode: Int32?
    @State private var lineOffset = 0
    @State private var duration: TimeInterval = 0
    @State private var isRunning = false
    @State private var scriptName = ""
    @State private var selectedScriptID: UUID?
    @State private var showsManager = false
    @State private var isDropTarget = false
    @State private var openedPath: String?

    private var choice: LanguageChoice {
        registry.choice(id: choiceID) ?? LanguageChoice(.bash)
    }

    private var activeLibraries: [ScriptLibrary] {
        registry.libraries(for: choice.id)
    }

    private var hasResult: Bool { !output.isEmpty || !errorOutput.isEmpty || exitCode != nil }

    var body: some View {
        VStack(spacing: 10) {
            toolbar
            if !activeLibraries.isEmpty { libraryStrip }
            editor
            if hasResult { console }
            saveRow
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .sheet(isPresented: $showsManager) {
            LanguageManagerSheet(registry: registry, tint: settings.tint) {
                showsManager = false
            }
        }
    }

    // MARK: Toolbar — separate glass pills

    private var toolbar: some View {
        HStack(spacing: 8) {
            languageMenu

            Spacer(minLength: 4)

            Button { openFile() } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.glassIcon())
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a script from disk (⌘O)")

            libraryMenu

            Button {
                runScript()
            } label: {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9))
                    }
                    Text(isRunning ? "Running" : "Run")
                }
            }
            .buttonStyle(.glass(tint: settings.tint, capsule: true))
            .disabled(isRunning)
            .keyboardShortcut("r", modifiers: .command)
            .help("Run this script (⌘R)")
        }
    }

    /// Grouped and labelled with each language's extension, so Luau and
    /// AutoHotkey read as the things that open `.luau` and `.ahk` rather
    /// than as two more names in a flat list.
    private var languageMenu: some View {
        Menu {
            Section("Shell") {
                languageButton(.bash)
                languageButton(.zsh)
            }
            Section("General") {
                languageButton(.python3)
                languageButton(.node)
                languageButton(.javascript)
                languageButton(.appleScript)
            }
            Section("Games & automation") {
                languageButton(.luau)
                languageButton(.autoHotkey)
            }
            if !registry.customChoices.isEmpty {
                Section("Yours") {
                    ForEach(registry.customChoices) { option in
                        Button("\(option.displayName)  ·  .\(option.fileExtension)") {
                            switchLanguage(to: option)
                        }
                    }
                }
            }
            Divider()
            Button("Add a language…") { showsManager = true }
        } label: {
            pillLabel(choice.displayName, symbol: "chevron.up.chevron.down", symbolSize: 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glass(Capsule(), style: .control)
    }

    private func languageButton(_ language: ScriptLanguage) -> some View {
        Button("\(language.displayName)  ·  .\(language.fileExtension)") {
            switchLanguage(to: LanguageChoice(language))
        }
    }

    private var libraryMenu: some View {
        Menu {
            Button("Open file…") { openFile() }
            Button("Save as file…") { saveToFile() }

            if !settings.recentFiles.isEmpty {
                Menu("Open recent") {
                    ForEach(settings.recentFiles, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            open(URL(fileURLWithPath: path))
                        }
                    }
                    Divider()
                    Button("Clear") { settings.recentFiles = [] }
                }
            }

            Divider()

            Menu("Libraries") {
                if registry.libraries.isEmpty {
                    Text("None yet")
                } else {
                    ForEach(registry.libraries) { library in
                        Button {
                            registry.toggle(library)
                        } label: {
                            Text("\(library.isEnabled ? "✓ " : "")\(library.name)  ·  \(library.scopeDescription)")
                        }
                    }
                }
            }

            if !registry.libraries.isEmpty {
                Menu("Paste a library in here") {
                    ForEach(registry.libraries) { library in
                        Button(library.name) { insert(library) }
                    }
                }
            }

            Button("Import a library file…") { importLibrary() }
            Button("Manage languages & libraries…") { showsManager = true }

            Divider()

            if store.scripts.isEmpty {
                Text("No saved scripts")
            } else {
                ForEach(store.scripts) { script in
                    Button("\(script.name)  ·  \(registry.choice(for: script).displayName)") { load(script) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(store.scripts) { script in
                        Button(script.name) { store.deleteScript(script) }
                    }
                }
            }
        } label: {
            pillLabel("Library", symbol: "tray.full", symbolSize: 9, symbolLeading: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glass(Capsule(), style: .control)
    }

    /// A quiet reminder that code you can't see is being prepended.
    private var libraryStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(activeLibraries.map(\.name).joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("runs first")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .glass(Capsule(), style: .panel)
    }

    private func pillLabel(_ text: String, symbol: String, symbolSize: CGFloat, symbolLeading: Bool = false) -> some View {
        HStack(spacing: 5) {
            if symbolLeading {
                Image(systemName: symbol).font(.system(size: symbolSize, weight: .medium))
            }
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            if !symbolLeading {
                Image(systemName: symbol).font(.system(size: symbolSize, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: Editor

    private var editor: some View {
        CodeEditor(
            text: $content,
            font: settings.editorNSFont(),
            showsLineNumbers: settings.showsLineNumbers,
            highlightsCurrentLine: settings.highlightsCurrentLine,
            tabWidth: settings.tabWidth,
            insertsSpaces: settings.insertsSpacesForTab,
            wrapsLines: settings.wrapsLines,
            autoIndents: settings.autoIndents,
            autoClosesBrackets: settings.autoClosesBrackets,
            placeholder: "Write \(choice.displayName) here, or drop a file in…"
        )
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .recessed)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(settings.tint.opacity(isDropTarget ? 0.9 : 0), lineWidth: 2)
        )
        // Drop a .ahk, .luau or anything else straight onto the editor.
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
            guard let data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { open(url) }
        }
        return true
    }

    // MARK: Console

    private var console: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(exitCode == 0 ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(consoleTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output + errorOutput, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.glassIcon(size: 20))
                .help("Copy the output")

                Button {
                    output = ""; errorOutput = ""; exitCode = nil; lineOffset = 0
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glassIcon(size: 20))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if lineOffset > 0 {
                Text("Line numbers below are \(lineOffset) higher than yours — that's the library code in front of your script.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if !output.isEmpty {
                        Text(output.trimmingCharacters(in: .newlines))
                            .font(settings.editorFont(delta: -1.5))
                            .textSelection(.enabled)
                    }
                    if !errorOutput.isEmpty {
                        Text(errorOutput.trimmingCharacters(in: .newlines))
                            .font(settings.editorFont(delta: -1.5))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if output.isEmpty && errorOutput.isEmpty {
                        Text("No output")
                            .font(settings.editorFont(delta: -1.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 120)
        }
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .recessed)
    }

    private var consoleTitle: String {
        guard let exitCode else { return "Output" }
        let timing = duration > 0.05 ? String(format: " · %.2fs", duration) : ""
        return (exitCode == 0 ? "Finished" : "Exit \(exitCode)") + timing
    }

    // MARK: Save row

    private var saveRow: some View {
        HStack(spacing: 8) {
            TextField("Script name", text: $scriptName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glass(Capsule(), style: .recessed)

            Button(selectedScriptID == nil ? "Save" : "Update") { saveScript() }
                .buttonStyle(.glass(capsule: true))
                .disabled(scriptName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut("s", modifiers: .command)

            if openedPath != nil {
                Button {
                    saveInPlace()
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .buttonStyle(.glassIcon())
                .help("Write back to the file this came from")
            }

            if selectedScriptID != nil || openedPath != nil {
                Button {
                    selectedScriptID = nil
                    openedPath = nil
                    scriptName = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glassIcon())
                .help("Start a new script")
            }
        }
    }

    // MARK: Actions

    private func switchLanguage(to option: LanguageChoice) {
        // Swapping in the starter only when nothing real is in the editor.
        if isStarterTemplate(content) {
            content = option.starterTemplate
        }
        choiceID = option.id
    }

    /// Built-in starters plus every custom language's, so switching between
    /// two user-added languages doesn't strand a template.
    private func isStarterTemplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if ScriptLanguage.isStarterTemplate(text) { return true }
        return registry.languages.contains {
            !$0.starterTemplate.isEmpty
                && $0.starterTemplate.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    private func insert(_ library: ScriptLibrary) {
        let separator = content.isEmpty || content.hasSuffix("\n") ? "" : "\n"
        content += separator + library.content + "\n"
    }

    private func runScript() {
        guard !isRunning else { return }
        isRunning = true
        output = ""
        errorOutput = ""
        exitCode = nil
        lineOffset = 0

        let options = settings.runOptions
        let currentChoice = choice
        let currentContent = content
        let libraries = registry.libraries

        Task { @MainActor in
            let result = await ScriptRunner.run(
                choice: currentChoice,
                content: currentContent,
                libraries: libraries,
                options: options
            )
            output = result.output
            errorOutput = result.error
            exitCode = result.exitCode
            lineOffset = result.libraryLineOffset
            duration = result.duration
            isRunning = false
        }
    }

    private func saveScript() {
        let trimmed = scriptName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Custom languages are stored alongside a sensible built-in, so a
        // script still opens in something runnable if its language is ever
        // deleted.
        let fallback = choice.builtIn ?? .bash
        let customID = choice.isCustom ? choice.id : nil

        let script: SavedScript
        if let id = selectedScriptID, let existing = store.scripts.first(where: { $0.id == id }) {
            script = SavedScript(
                id: existing.id,
                name: trimmed,
                language: fallback,
                content: content,
                updatedAt: Date(),
                customLanguageID: customID
            )
        } else {
            script = SavedScript(
                name: trimmed,
                language: fallback,
                content: content,
                customLanguageID: customID
            )
        }
        store.upsertScript(script)
        selectedScriptID = script.id
    }

    private func load(_ script: SavedScript) {
        selectedScriptID = script.id
        openedPath = nil
        scriptName = script.name
        choiceID = registry.choice(for: script).id
        content = script.content
    }

    // MARK: Files on disk

    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        // Deliberately no `allowedContentTypes`. macOS has no registered
        // UTType for .ahk or .luau — nothing on the system claims them —
        // so any filter at all greys them out in the panel and they can't
        // be selected. An unfiltered panel is the only one that can open
        // the two file types this app exists to run.
        panel.message = "Open a script — .ahk, .luau, .sh, .py, .js, anything"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// One path in, used by the panel, the recents menu and drag-and-drop.
    private func open(_ url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            content = text
            scriptName = url.deletingPathExtension().lastPathComponent
            selectedScriptID = nil
            openedPath = url.path
            if let detected = registry.choice(forFileExtension: url.pathExtension) {
                choiceID = detected.id
            }
            settings.noteRecentFile(url.path)
            output = ""
            errorOutput = ""
            exitCode = nil
        } catch {
            // A non-UTF8 file is the usual cause — a compiled .scpt, say.
            errorOutput = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            exitCode = -1
        }
    }

    private func saveInPlace() {
        guard let path = openedPath else { return }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            output = "Saved to \(path)"
            errorOutput = ""
            exitCode = 0
        } catch {
            errorOutput = "Could not save: \(error.localizedDescription)"
            exitCode = -1
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        let suggested = scriptName.trimmingCharacters(in: .whitespaces)
        let ext = choice.fileExtension.isEmpty ? "txt" : choice.fileExtension
        panel.nameFieldStringValue = (suggested.isEmpty ? "script" : suggested) + "." + ext
        // Same reasoning as the open panel: no content-type filter, or
        // saving as .ahk fights the panel.
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            openedPath = url.path
            settings.noteRecentFile(url.path)
        } catch {
            errorOutput = "Could not save: \(error.localizedDescription)"
            exitCode = -1
        }
    }

    private func importLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Pick a file to paste in front of your scripts before they run"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let library = ScriptLibrary(
                name: url.deletingPathExtension().lastPathComponent,
                content: text,
                languageIDs: [choice.id],
                sourcePath: url.path
            )
            registry.upsert(library)
        } catch {
            errorOutput = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            exitCode = -1
        }
    }
}
