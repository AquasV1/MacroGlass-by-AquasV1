import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: MacroStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var automation: AutomationController
    @ObservedObject var registry: LanguageRegistry
    @ObservedObject var hotkeys: HotkeyCenter

    @StateObject private var toolchains = ToolchainStatus()
    @State private var accessibilityGranted = AccessibilityPermission.isTrusted
    @State private var showResetConfirm = false
    @State private var showsManager = false
    @State private var hotkeySlot: HotkeySlot?
    @State private var note: String?

    private enum HotkeySlot: String, Identifiable {
        case panic
        case record
        case clicker
        var id: String { rawValue }

        var title: String {
            switch self {
            case .panic: return "Stop everything"
            case .record: return "Start and stop recording"
            case .clicker: return "Start and stop the auto clicker"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                automationCard
                playbackCard
                recordingCard
                hotkeysCard
                languagesCard
                toolchainsCard
                autoHotkeyCard
                executionCard
                editorCard
                appearanceCard
                generalCard
                permissionsCard
                dataCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
        .onAppear {
            accessibilityGranted = AccessibilityPermission.isTrusted
            toolchains.refresh()
        }
        .sheet(isPresented: $showsManager) {
            LanguageManagerSheet(registry: registry, tint: settings.tint) {
                showsManager = false
            }
        }
        .sheet(item: $hotkeySlot) { slot in
            HotkeySheet(
                title: slot.title,
                current: currentHotkey(for: slot),
                tint: settings.tint,
                conflictCheck: { hotkeys.conflict(for: $0, excluding: nil) },
                onSave: { hotkey in
                    switch slot {
                    case .panic: settings.panicHotkey = hotkey
                    case .record: settings.recordHotkey = hotkey
                    case .clicker: settings.clickerHotkey = hotkey
                    }
                    hotkeySlot = nil
                },
                onCancel: { hotkeySlot = nil }
            )
        }
    }

    // MARK: Automation

    private var automationCard: some View {
        card("Auto-execute") {
            row("Trigger") {
                menuPill(settings.autoRunTrigger.label) {
                    ForEach(AutoRunTrigger.allCases) { trigger in
                        Button(trigger.label) { settings.autoRunTrigger = trigger }
                    }
                }
            }

            if settings.autoRunTrigger != .off {
                row("Script") {
                    menuPill(selectedScriptName) {
                        if store.scripts.isEmpty {
                            Text("Save a script first")
                        } else {
                            ForEach(store.scripts) { script in
                                Button(script.name) { settings.autoRunScriptID = script.id.uuidString }
                            }
                        }
                    }
                }

                if settings.autoRunTrigger == .interval {
                    row("Every") {
                        stepperPill(
                            "\(settings.autoRunIntervalMinutes) min",
                            onDown: { settings.autoRunIntervalMinutes = max(1, settings.autoRunIntervalMinutes - 5) },
                            onUp: { settings.autoRunIntervalMinutes = min(720, settings.autoRunIntervalMinutes + 5) }
                        )
                    }
                }

                toggleRow("Warn me when a run fails", isOn: $settings.autoRunNotifies)

                HStack(spacing: 8) {
                    Button("Run now") { automation.run(reason: "manual") }
                        .buttonStyle(.glass(capsule: true))
                        .disabled(automation.selectedScript == nil || automation.isRunning)

                    if let date = automation.lastRunDate {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(automation.lastRunExitCode == 0 ? Color.green : Color.red)
                                .frame(width: 5, height: 5)
                            Text("\(automation.lastRunReason ?? "ran") · \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            caption(automation.statusLine)
        }
    }

    private var selectedScriptName: String {
        store.scripts.first { $0.id.uuidString == settings.autoRunScriptID }?.name ?? "None selected"
    }

    // MARK: Playback

    private var playbackCard: some View {
        card("Playback") {
            sliderRow(
                "Speed",
                value: $settings.playbackSpeed,
                range: 0.25...4,
                display: String(format: "%.2g×", settings.playbackSpeed)
            )

            toggleRow("Loop until stopped", isOn: $settings.loopsForever)

            if !settings.loopsForever {
                row("Repeat") {
                    stepperPill(
                        settings.repeatCount == 1 ? "Once" : "\(settings.repeatCount)×",
                        onDown: { settings.repeatCount = max(1, settings.repeatCount - 1) },
                        onUp: { settings.repeatCount = min(999, settings.repeatCount + 1) }
                    )
                }
            }

            row("Countdown") {
                stepperPill(
                    settings.countdownSeconds == 0 ? "None" : "\(settings.countdownSeconds)s",
                    onDown: { settings.countdownSeconds = max(0, settings.countdownSeconds - 1) },
                    onUp: { settings.countdownSeconds = min(30, settings.countdownSeconds + 1) }
                )
            }

            row("Pause between loops") {
                stepperPill(
                    settings.pauseBetweenLoops == 0 ? "None" : String(format: "%.1fs", settings.pauseBetweenLoops),
                    onDown: { settings.pauseBetweenLoops = max(0, settings.pauseBetweenLoops - 0.5) },
                    onUp: { settings.pauseBetweenLoops = min(60, settings.pauseBetweenLoops + 0.5) }
                )
            }

            sliderRow(
                "Timing jitter",
                value: $settings.playbackJitterPercent,
                range: 0...50,
                display: settings.playbackJitterPercent == 0
                    ? "Off"
                    : String(format: "±%.0f%%", settings.playbackJitterPercent)
            )

            toggleRow("Put the pointer back afterwards", isOn: $settings.restoresCursorAfterPlayback)

            caption(settings.playbackJitterPercent > 0
                    ? "Each gap is nudged at random, so a long loop doesn't replay on a metronome."
                    : "A countdown gives you time to switch to the target window before playback starts.")
        }
    }

    // MARK: Recording

    private var recordingCard: some View {
        card("Recording") {
            toggleRow("Capture mouse movement", isOn: $settings.recordsMouseMovement)
            toggleRow("Stop recording with Esc", isOn: $settings.stopsWithEscape)
            toggleRow("Skip bare modifier presses", isOn: $settings.ignoresModifierOnlyKeys)

            row("Countdown before recording") {
                stepperPill(
                    settings.recordCountdownSeconds == 0 ? "None" : "\(settings.recordCountdownSeconds)s",
                    onDown: { settings.recordCountdownSeconds = max(0, settings.recordCountdownSeconds - 1) },
                    onUp: { settings.recordCountdownSeconds = min(30, settings.recordCountdownSeconds + 1) }
                )
            }

            row("Stop automatically after") {
                stepperPill(
                    settings.maxRecordingSeconds == 0 ? "Never" : "\(settings.maxRecordingSeconds)s",
                    onDown: { settings.maxRecordingSeconds = max(0, settings.maxRecordingSeconds - 15) },
                    onUp: { settings.maxRecordingSeconds = min(3600, settings.maxRecordingSeconds + 15) }
                )
            }

            caption(settings.recordsMouseMovement
                    ? "Pointer moves are sampled ~30×/sec, so cursor paths replay but files stay small."
                    : "Only clicks, keys and scrolling are captured.")
        }
    }

    // MARK: Hotkeys

    private var hotkeysCard: some View {
        card("Hotkeys") {
            hotkeyRow("Stop everything", hotkey: settings.panicHotkey) { hotkeySlot = .panic }
            hotkeyRow("Start / stop recording", hotkey: settings.recordHotkey) { hotkeySlot = .record }
            hotkeyRow("Start / stop the clicker", hotkey: settings.clickerHotkey) { hotkeySlot = .clicker }

            HStack(spacing: 7) {
                Circle()
                    .fill(hotkeys.isListening ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 5, height: 5)
                Text(hotkeys.isListening
                     ? "Listening globally"
                     : (nothingBound ? "Nothing bound yet" : "Not listening"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if boundMacroCount > 0 {
                    Text("\(boundMacroCount) macro\(boundMacroCount == 1 ? "" : "s") bound")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if let reason = hotkeys.failureReason {
                caption(reason)
            } else {
                caption("Per-macro triggers are set from the ⋯ menu next to a macro in the Record tab. A matched combination is swallowed, so the app in front never sees it.")
            }
        }
    }

    private var boundMacroCount: Int {
        store.macros.filter { $0.hotkey != nil }.count
    }

    private var nothingBound: Bool {
        boundMacroCount == 0
            && settings.panicHotkey == nil
            && settings.recordHotkey == nil
            && settings.clickerHotkey == nil
    }

    private func currentHotkey(for slot: HotkeySlot) -> MacroHotkey? {
        switch slot {
        case .panic: return settings.panicHotkey
        case .record: return settings.recordHotkey
        case .clicker: return settings.clickerHotkey
        }
    }

    private func hotkeyRow(_ title: String, hotkey: MacroHotkey?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 6)
            Text(hotkey?.displayName ?? "None")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hotkey == nil ? Color.secondary : Color.primary)
            Button(hotkey == nil ? "Set…" : "Change…", action: action)
                .buttonStyle(.glass(capsule: true))
        }
    }

    // MARK: Languages & libraries

    private var languagesCard: some View {
        card("Languages & libraries") {
            row("Your languages") {
                Text(registry.languages.isEmpty ? "None" : registry.languages.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            row("Libraries") {
                Text(registry.libraries.isEmpty
                     ? "None"
                     : "\(registry.libraries.filter(\.isEnabled).count) on of \(registry.libraries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Manage…") { showsManager = true }
                    .buttonStyle(.glass(tint: settings.tint, capsule: true))
                if registry.libraries.contains(where: { !$0.sourcePath.isEmpty }) {
                    Button("Reload from disk") {
                        let count = registry.refreshImportedLibraries()
                        note = count == 0 ? "Everything was already current." : "Refreshed \(count) library file\(count == 1 ? "" : "s")."
                    }
                    .buttonStyle(.glass(capsule: true))
                }
                Spacer()
            }

            if let note {
                caption(note)
            } else {
                caption("Add an interpreter — Ruby, Deno, a wrapper script of your own — and it shows up in the Script tab's language pill.")
            }
        }
    }

    // MARK: Toolchains

    private var toolchainsCard: some View {
        card("Toolchains") {
            ForEach(ScriptLanguage.allCases) { language in
                toolchainRow(language)
            }

            if toolchains.isInstalling || !toolchains.installLog.isEmpty {
                Text(toolchains.installLog)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Rescan") { toolchains.refresh() }
                    .buttonStyle(.glass(capsule: true))
                Button("Reveal folder") { NSWorkspace.shared.open(Toolchain.managedDirectory) }
                    .buttonStyle(.glass(capsule: true))
                Spacer()
            }

            caption("Interpreters are found on your PATH, in Homebrew, or installed here by MacroGlass.")
        }
    }

    private func toolchainRow(_ language: ScriptLanguage) -> some View {
        let installed = toolchains.isInstalled(language)
        let isBuiltIn: Bool = {
            if case .builtIn = language.runtime { return true }
            return false
        }()

        return HStack(spacing: 7) {
            Circle()
                .fill(installed ? Color.green : Color.orange)
                .frame(width: 5, height: 5)

            Text(language.displayName)
                .font(.system(size: 12))

            Spacer(minLength: 6)

            if isBuiltIn {
                Text("built-in")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if let path = toolchains.path(for: language) {
                Text(shorten(path))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            } else if language == .luau {
                Button(toolchains.isInstalling ? "Installing…" : "Install") {
                    toolchains.installLuau()
                }
                .buttonStyle(.glass(tint: settings.tint, capsule: true))
                .disabled(toolchains.isInstalling)
            } else {
                Text("not found")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shorten(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: AutoHotkey

    private var autoHotkeyCard: some View {
        card("AutoHotkey") {
            toggleRow("Map ^ to Command instead of Control", isOn: $settings.ahkMapsControlToCommand)

            HStack(spacing: 8) {
                Text("AutoHotkey.exe").font(.system(size: 12.5))
                Spacer(minLength: 6)
                Text(settings.ahkExecutablePath.isEmpty ? "built-in engine" : shorten(settings.ahkExecutablePath))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button(settings.ahkExecutablePath.isEmpty ? "Choose…" : "Clear") {
                    if settings.ahkExecutablePath.isEmpty {
                        chooseAutoHotkeyExecutable()
                    } else {
                        settings.ahkExecutablePath = ""
                    }
                }
                .buttonStyle(.glass(capsule: true))
                .disabled(settings.ahkExecutablePath.isEmpty && toolchains.winePath == nil)
            }

            caption(autoHotkeyStatus)
        }
    }

    private var autoHotkeyStatus: String {
        if !settings.ahkExecutablePath.isEmpty {
            return "Scripts run through the real AutoHotkey under Wine."
        }
        if let wine = toolchains.winePath {
            return "Wine found at \(shorten(wine)) — point it at an AutoHotkey.exe to run full AHK. Otherwise the built-in engine handles Send, Click, MouseMove, Sleep, MsgBox, Run, Loop and %variables%."
        }
        return "AutoHotkey is Windows-only, so scripts run on the built-in engine: Send, Click, MouseMove, Sleep, MsgBox, Run, Loop and %variables%. Install Wine to run real AHK instead."
    }

    private func chooseAutoHotkeyExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.message = "Choose AutoHotkey.exe"
        if panel.runModal() == .OK, let url = panel.url {
            settings.ahkExecutablePath = url.path
        }
    }

    // MARK: Script execution

    private var executionCard: some View {
        card("Script execution") {
            row("Stop a run after") {
                stepperPill(
                    settings.scriptTimeoutSeconds == 0 ? "Never" : "\(settings.scriptTimeoutSeconds)s",
                    onDown: { settings.scriptTimeoutSeconds = max(0, settings.scriptTimeoutSeconds - 5) },
                    onUp: { settings.scriptTimeoutSeconds = min(3600, settings.scriptTimeoutSeconds + 5) }
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("WORKING DIRECTORY")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Wherever the app was launched from", text: $settings.scriptWorkingDirectory)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
                    Button("Choose…") { chooseWorkingDirectory() }
                        .buttonStyle(.glass(capsule: true))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("EXTRA PATH")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                TextField("/opt/my-tools/bin:/another/bin", text: $settings.scriptExtraPATH)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
            }

            caption("Homebrew's bin directories are already on the path scripts get. A timeout kills a runaway loop instead of leaving it spinning.")
        }
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Run scripts from this folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.scriptWorkingDirectory = url.path
        }
    }

    // MARK: Editor

    private var editorCard: some View {
        card("Script editor") {
            row("Font") {
                menuPill(settings.editorFontDisplayName) {
                    Button("System Mono") { settings.editorFontName = AppSettings.systemFontToken }
                    Divider()
                    ForEach(AppSettings.monospacedFamilies, id: \.self) { family in
                        Button(family) { settings.editorFontName = family }
                    }
                }
            }

            sliderRow(
                "Size",
                value: $settings.editorFontSize,
                range: 9...20,
                display: String(format: "%.0f pt", settings.editorFontSize)
            )

            row("Tab width") {
                menuPill("\(settings.tabWidth) spaces") {
                    ForEach([2, 4, 8], id: \.self) { width in
                        Button("\(width) spaces") { settings.tabWidth = width }
                    }
                }
            }

            toggleRow("Insert spaces for Tab", isOn: $settings.insertsSpacesForTab)
            toggleRow("Line numbers", isOn: $settings.showsLineNumbers)
            toggleRow("Highlight current line", isOn: $settings.highlightsCurrentLine)
            toggleRow("Wrap long lines", isOn: $settings.wrapsLines)
            toggleRow("Keep indentation on Return", isOn: $settings.autoIndents)
            toggleRow("Close brackets and quotes", isOn: $settings.autoClosesBrackets)

            Text("The quick brown fox jumps over 1234567890")
                .font(settings.editorFont())
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
        }
    }

    // MARK: Appearance

    private var appearanceCard: some View {
        card("Appearance") {
            row("Glass tint") {
                ColorPicker("", selection: Binding(
                    get: { settings.tint },
                    set: { settings.glassTintHex = $0.hexString }
                ))
                .labelsHidden()
            }

            sliderRow(
                "Glass strength",
                value: $settings.glassIntensity,
                range: 0.3...1.6,
                display: String(format: "%.0f%%", settings.glassIntensity * 100)
            )

            toggleRow("Float above other apps", isOn: $settings.floatOnTop)
        }
    }

    // MARK: General

    private var generalCard: some View {
        card("General") {
            row("Open to") {
                menuPill(settings.startupMode.label) {
                    ForEach(StartupMode.allCases) { option in
                        Button(option.label) { settings.startupMode = option }
                    }
                }
            }

            toggleRow("Launch at login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    toggleLaunchAtLogin(newValue)
                }
            ))

            caption(settings.startupMode == .ask
                    ? "The start screen asks which half you want. The grid button in the top-left corner goes back to it."
                    : "MacroGlass opens straight into \(settings.startupMode.label). The grid button in the top-left corner still goes back to the start screen.")
            caption("⌘⇧R starts and stops recording · ⌘R runs the script · ⌘S saves it · ⌘O opens a file.")
        }
    }

    // MARK: Permissions

    private var permissionsCard: some View {
        card("Permissions") {
            HStack(spacing: 7) {
                Circle()
                    .fill(accessibilityGranted ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(accessibilityGranted ? "Accessibility granted" : "Accessibility not granted")
                    .font(.system(size: 12.5))
                Spacer(minLength: 6)
                Button("Recheck") { accessibilityGranted = AccessibilityPermission.isTrusted }
                    .buttonStyle(.glass(capsule: true))
                Button("Open") { AccessibilityPermission.openSystemSettings() }
                    .buttonStyle(.glass(capsule: true))
            }
            caption("Recording, playback and global hotkeys all need it. Rebuilding the app can reset the grant — re-tick MacroGlass in System Settings if things stop responding.")
        }
    }

    // MARK: Data

    private var dataCard: some View {
        card("Data") {
            row("Macros & scripts") {
                Button("Reveal") { NSWorkspace.shared.open(dataDirectory) }
                    .buttonStyle(.glass(capsule: true))
            }
            row("All settings") {
                Button(showResetConfirm ? "Tap to confirm" : "Reset") {
                    if showResetConfirm {
                        settings.resetToDefaults()
                        showResetConfirm = false
                    } else {
                        showResetConfirm = true
                    }
                }
                .buttonStyle(.glass(tint: showResetConfirm ? .red : nil, capsule: true))
            }
            caption("\(store.macros.count) macros · \(store.scripts.count) scripts · \(registry.languages.count) languages · \(registry.libraries.count) libraries, all JSON in Application Support.")
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .panel)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 6)
            content()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12.5))
                Spacer()
                Text(display)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .tint(settings.tint)
        }
    }

    private func menuPill<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .glass(Capsule(), style: .control)
    }

    private func stepperPill(_ label: String, onDown: @escaping () -> Void, onUp: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: onDown) { Image(systemName: "minus") }
                .buttonStyle(.glassIcon(size: 22))
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 52)
            Button(action: onUp) { Image(systemName: "plus") }
                .buttonStyle(.glassIcon(size: 22))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dataDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacroGlass", isDirectory: true)
    }

    private func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Launch at login error: \(error)")
        }
    }
}
