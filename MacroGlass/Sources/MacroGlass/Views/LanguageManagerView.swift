import SwiftUI
import AppKit

/// Add a language MacroGlass has never heard of, or a library that gets
/// pasted in front of your scripts before they run. Reached from the
/// Library pill in the Script tab and from Settings.
struct LanguageManagerSheet: View {
    @ObservedObject var registry: LanguageRegistry
    let tint: Color
    var onClose: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case languages = "Languages"
        case libraries = "Libraries"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .languages
    @State private var editingLanguage: CustomLanguage?
    @State private var editingLibrary: ScriptLibrary?
    @State private var probe: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 8) {
                ForEach(Tab.allCases) { option in
                    Button(option.rawValue) {
                        tab = option
                        editingLanguage = nil
                        editingLibrary = nil
                        probe = nil
                    }
                    .buttonStyle(.glass(tint: tab == option ? tint : nil, capsule: true))
                }
                Spacer()
                addMenu
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .languages: languageList
                    case .libraries: libraryList
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(height: 330)

            HStack {
                if let probe {
                    Text(probe)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(GlassSurface(shape: Rectangle(), style: .window))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Languages & libraries")
                .font(.system(size: 13, weight: .semibold))
            Text(tab == .languages
                 ? "Anything with an interpreter that takes a file path can run here."
                 : "A library is pasted in front of your script before it runs.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var addMenu: some View {
        Menu {
            if tab == .languages {
                Button("Blank language") {
                    editingLanguage = CustomLanguage(name: "New language", interpreter: "")
                }
                Divider()
                Section("Start from") {
                    ForEach(CustomLanguage.presets) { preset in
                        Button(preset.name) {
                            var copy = preset
                            copy.id = UUID()
                            editingLanguage = copy
                        }
                    }
                }
            } else {
                Button("Blank library") {
                    editingLibrary = ScriptLibrary(name: "New library", content: "")
                }
                Button("From a file…") { importLibraryFile() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                Text("Add").font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glass(Capsule(), style: .control)
    }

    // MARK: Languages

    @ViewBuilder
    private var languageList: some View {
        if let editing = editingLanguage {
            LanguageEditor(
                language: editing,
                tint: tint,
                onProbe: { probeInterpreter($0) },
                onSave: { saved in
                    registry.upsert(saved)
                    editingLanguage = nil
                },
                onCancel: { editingLanguage = nil }
            )
            // The editor holds a @State copy, so it needs a fresh identity
            // per language or SwiftUI reuses the old one's contents.
            .id(editing.id)
        }

        if registry.languages.isEmpty && editingLanguage == nil {
            emptyNote("Nothing added yet. “Add” starts from a preset or a blank one.")
        }

        ForEach(registry.languages) { language in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.name)
                        .font(.system(size: 12.5, weight: .medium))
                    Text("\(language.interpreter) \(language.argumentLine) · .\(language.fileExtension)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Button("Check") { probeInterpreter(language.interpreter) }
                    .buttonStyle(.glass(capsule: true))
                Button("Edit") { editingLanguage = language }
                    .buttonStyle(.glass(capsule: true))
                Button {
                    registry.delete(language)
                    if editingLanguage?.id == language.id { editingLanguage = nil }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glassIcon(size: 22))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .panel)
        }
    }

    // MARK: Libraries

    @ViewBuilder
    private var libraryList: some View {
        if let editing = editingLibrary {
            LibraryEditor(
                library: editing,
                choices: registry.choices,
                tint: tint,
                onSave: { saved in
                    registry.upsert(saved)
                    editingLibrary = nil
                },
                onCancel: { editingLibrary = nil }
            )
            .id(editing.id)
        }

        if registry.libraries.isEmpty && editingLibrary == nil {
            emptyNote("No libraries yet. Add one and every script in its languages gets it for free.")
        }

        ForEach(registry.libraries) { library in
            HStack(spacing: 8) {
                Circle()
                    .fill(library.isEnabled ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .font(.system(size: 12.5, weight: .medium))
                    Text("\(library.lineCount) lines · \(library.scopeDescription)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)

                Button(library.isEnabled ? "Disable" : "Enable") { registry.toggle(library) }
                    .buttonStyle(.glass(capsule: true))
                Button("Edit") { editingLibrary = library }
                    .buttonStyle(.glass(capsule: true))
                Button {
                    registry.delete(library)
                    if editingLibrary?.id == library.id { editingLibrary = nil }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glassIcon(size: 22))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .panel)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 18)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .recessed)
    }

    // MARK: Actions

    /// Resolves an interpreter the same way a run would, so a typo shows up
    /// here rather than as a confusing 127 later.
    private func probeInterpreter(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            probe = "No interpreter set yet."
            return
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            probe = FileManager.default.isExecutableFile(atPath: expanded)
                ? "Found: \(expanded)"
                : "Nothing executable at \(expanded)"
            return
        }
        if let url = Toolchain.resolve(trimmed) {
            probe = "Found: \(url.path)"
        } else {
            probe = "“\(trimmed)” isn't on PATH, in Homebrew, or in your login shell."
        }
    }

    private func importLibraryFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Pick a file to use as a library"

        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        editingLibrary = ScriptLibrary(
            name: url.deletingPathExtension().lastPathComponent,
            content: text,
            sourcePath: url.path
        )
    }
}

// MARK: - Editing one language

private struct LanguageEditor: View {
    @State var language: CustomLanguage
    let tint: Color
    var onProbe: (String) -> Void
    var onSave: (CustomLanguage) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            field("Name", text: $language.name, placeholder: "Ruby")

            HStack(spacing: 8) {
                field("Interpreter", text: $language.interpreter, placeholder: "ruby or /usr/bin/ruby")
                Button("Choose…") { chooseInterpreter() }
                    .buttonStyle(.glass(capsule: true))
                Button("Check") { onProbe(language.interpreter) }
                    .buttonStyle(.glass(capsule: true))
            }

            field("Arguments", text: Binding(
                get: { language.argumentLine },
                set: { language.argumentLine = $0 }
            ), placeholder: CustomLanguage.scriptPlaceholder)

            Text("\(CustomLanguage.scriptPlaceholder) stands in for the file your script is written to. Leave it out and it's appended last.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                field("Extension", text: $language.fileExtension, placeholder: "rb")
                field("Comment", text: $language.commentPrefix, placeholder: "#")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("STARTER TEMPLATE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                TextEditor(text: $language.starterTemplate)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 64)
                    .padding(6)
                    .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass(capsule: true))
                Spacer()
                Button("Save") { onSave(language) }
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .disabled(
                        language.name.trimmingCharacters(in: .whitespaces).isEmpty
                        || language.interpreter.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .panel)
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
        }
    }

    private func chooseInterpreter() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.showsHiddenFiles = true
        panel.message = "Choose the interpreter binary"
        if panel.runModal() == .OK, let url = panel.url {
            language.interpreter = url.path
        }
    }
}

// MARK: - Editing one library

private struct LibraryEditor: View {
    @State var library: ScriptLibrary
    let choices: [LanguageChoice]
    let tint: Color
    var onSave: (ScriptLibrary) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text("NAME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                TextField("Helpers", text: $library.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
            }

            HStack(spacing: 8) {
                Text("Applies to").font(.system(size: 11.5))
                Spacer(minLength: 6)
                Menu {
                    Button("Every language") { library.languageIDs = [] }
                    Divider()
                    ForEach(choices) { option in
                        Button {
                            toggle(option.id)
                        } label: {
                            Text("\(library.languageIDs.contains(option.id) ? "✓ " : "")\(option.displayName)")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(library.scopeDescription)
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .glass(Capsule(), style: .control)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CODE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                TextEditor(text: $library.content)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(6)
                    .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
            }

            if !library.sourcePath.isEmpty {
                Text("Imported from \(library.sourcePath)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass(capsule: true))
                Spacer()
                Button("Save") { onSave(library) }
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .disabled(library.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .panel)
    }

    private func toggle(_ id: String) {
        if let index = library.languageIDs.firstIndex(of: id) {
            library.languageIDs.remove(at: index)
        } else {
            library.languageIDs.append(id)
        }
    }
}
