import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RecordView: View {
    @ObservedObject var store: MacroStore
    @ObservedObject var recorder: MacroRecorder
    @ObservedObject var player: MacroPlayer
    @ObservedObject var hotkeys: HotkeyCenter
    @ObservedObject var settings: AppSettings

    @State private var newMacroName = ""
    @State private var search = ""
    @State private var activeSheet: ActiveSheet?
    @State private var pendingAppendTarget: Macro?
    @State private var pulse = false
    @State private var note: String?

    private enum ActiveSheet: Identifiable {
        case nameNewMacro
        case rename(Macro)
        case hotkey(Macro)
        case inspect(Macro)

        var id: String {
            switch self {
            case .nameNewMacro: return "new"
            case .rename(let macro): return "rename-\(macro.id)"
            case .hotkey(let macro): return "hotkey-\(macro.id)"
            case .inspect(let macro): return "inspect-\(macro.id)"
            }
        }
    }

    private var filtered: [Macro] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return store.macros }
        return store.macros.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !AccessibilityPermission.isTrusted {
                permissionBanner
            }

            if player.isPlaying {
                nowPlaying
            }

            recordControls
            statusLine

            if recorder.isRecording && !recorder.liveEvents.isEmpty {
                liveFeed
            }

            if let note {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            listHeader

            if store.macros.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                noMatches
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { macro in
                            MacroRow(
                                macro: macro,
                                tint: settings.tint,
                                isPlaying: player.playingMacroID == macro.id,
                                canPlay: !player.isPlaying,
                                onPlay: { play(macro) },
                                onExtend: { extend(macro) },
                                onRename: { activeSheet = .rename(macro) },
                                onHotkey: { activeSheet = .hotkey(macro) },
                                onInspect: { activeSheet = .inspect(macro) },
                                onDuplicate: { _ = store.duplicate(macro) },
                                onTrim: { trim(macro) },
                                onExport: { export(macro) },
                                onMoveUp: { store.moveMacro(macro, by: -1) },
                                onMoveDown: { store.moveMacro(macro, by: 1) },
                                onDelete: { store.deleteMacro(macro) }
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .nameNewMacro:
                NameMacroSheet(
                    name: $newMacroName,
                    title: "Name this macro",
                    tint: settings.tint,
                    onSave: { saveTake() },
                    onCancel: {
                        recorder.discard()
                        activeSheet = nil
                    }
                )
            case .rename(let macro):
                RenameSheet(macro: macro, tint: settings.tint) { newName in
                    store.rename(macro, to: newName)
                    activeSheet = nil
                } onCancel: {
                    activeSheet = nil
                }
            case .hotkey(let macro):
                HotkeySheet(
                    title: "Trigger “\(macro.name)”",
                    current: macro.hotkey,
                    tint: settings.tint,
                    conflictCheck: { hotkeys.conflict(for: $0, excluding: macro.id) }
                ) { hotkey in
                    store.setHotkey(hotkey, for: macro)
                    activeSheet = nil
                } onCancel: {
                    activeSheet = nil
                }
            case .inspect(let macro):
                MacroInspectorSheet(
                    macro: macro,
                    tint: settings.tint,
                    onSave: { edited in
                        store.updateMacro(edited)
                        note = "Saved “\(edited.name)” — \(edited.events.count) steps."
                        activeSheet = nil
                    },
                    onClose: { activeSheet = nil }
                )
            }
        }
        .onChange(of: recorder.isRecording) { wasRecording, recording in
            guard wasRecording, !recording else { return }
            pulse = false
            finishTake()
        }
    }

    // MARK: Controls

    private var recordControls: some View {
        HStack(spacing: 8) {
            Button {
                toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: recordSymbol)
                    Text(recordLabel)
                }
            }
            .buttonStyle(.glass(
                tint: (recorder.isRecording || recorder.isArmed) ? .red : settings.tint,
                capsule: true,
                fullWidth: true
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])

            if player.isPlaying {
                Button("Stop") { player.stop() }
                    .buttonStyle(.glass(tint: .red, capsule: true))
                    .help("Stop playback")
            }

            Menu {
                Button("Import macros…") { importMacros() }
                if !store.macros.isEmpty {
                    Button("Export all…") { exportAll() }
                }
                Divider()
                Button(recorder.liveEvents.isEmpty ? "Nothing to re-save" : "Save the last take again") {
                    guard !recorder.liveEvents.isEmpty else { return }
                    newMacroName = ""
                    activeSheet = .nameNewMacro
                }
                .disabled(recorder.liveEvents.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .glass(Circle(), style: .control)
        }
    }

    private var recordSymbol: String {
        if recorder.isArmed { return "timer" }
        return recorder.isRecording ? "stop.fill" : "record.circle"
    }

    private var recordLabel: String {
        if recorder.isArmed { return "Starting in \(recorder.countdownRemaining)…" }
        if recorder.isRecording { return pendingAppendTarget == nil ? "Stop" : "Stop extending" }
        return "Record"
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(settings.tint)
                Text(playbackHeadline)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button("Stop") { player.stop() }
                    .buttonStyle(.glass(tint: .red, capsule: true))
            }

            if player.countdownRemaining == 0 {
                ProgressView(value: min(max(player.progress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(settings.tint)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), style: .panel)
    }

    private var playbackHeadline: String {
        if player.countdownRemaining > 0 {
            return "“\(player.playingMacroName)” in \(player.countdownRemaining)…"
        }
        if player.totalLoops == 0 {
            return "“\(player.playingMacroName)” · loop \(player.currentLoop) of ∞"
        }
        if player.totalLoops > 1 {
            return "“\(player.playingMacroName)” · loop \(player.currentLoop) of \(player.totalLoops)"
        }
        return "Playing “\(player.playingMacroName)”"
    }

    /// The last few captured events, so you can see the tap is actually
    /// picking things up instead of trusting a counter.
    private var liveFeed: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(recorder.liveEvents.suffix(4).reversed(), id: \.id) { event in
                HStack(spacing: 7) {
                    Image(systemName: event.symbol)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 13)
                    Text(event.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.2fs", event.timestamp))
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 11, style: .continuous), style: .recessed)
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            if recorder.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                Text(liveSummary)
            } else if recorder.isArmed {
                Text("Switch to the window you want to record in.")
            } else if !recorder.liveEvents.isEmpty {
                Text("\(recorder.liveEvents.count) events in the last take")
            } else {
                Text(playbackSummary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(height: 14)
    }

    private var liveSummary: String {
        let seconds = String(format: "%.0fs", recorder.elapsed)
        var line = "\(recorder.liveEvents.count) events · \(seconds)"
        if settings.maxRecordingSeconds > 0 {
            line += " of \(settings.maxRecordingSeconds)s"
        }
        if settings.stopsWithEscape {
            line += " · Esc to stop"
        }
        return line
    }

    private var playbackSummary: String {
        var parts: [String] = []
        if settings.playbackSpeed != 1 { parts.append(String(format: "%.2g× speed", settings.playbackSpeed)) }
        if settings.loopsForever {
            parts.append("looping")
        } else if settings.repeatCount > 1 {
            parts.append("×\(settings.repeatCount)")
        }
        if settings.countdownSeconds > 0 { parts.append("\(settings.countdownSeconds)s countdown") }
        if settings.playbackJitterPercent > 0 { parts.append(String(format: "±%.0f%% jitter", settings.playbackJitterPercent)) }
        return parts.isEmpty ? "Clicks, keys and scrolling are captured system-wide." : "Playback: " + parts.joined(separator: " · ")
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("SAVED MACROS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            if store.macros.count > 3 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    TextField("Filter", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 96)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .glass(Capsule(), style: .recessed)
            }

            Text("\(store.macros.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing recorded yet")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .recessed)
    }

    private var noMatches: some View {
        Text("No macro matches “\(search)”.")
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .recessed)
    }

    private var permissionBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.yellow)
            Text("Accessibility access is needed to record and replay.")
                .font(.system(size: 11))
            Spacer(minLength: 6)
            Button("Grant") {
                AccessibilityPermission.requestPrompt()
                AccessibilityPermission.openSystemSettings()
            }
            .buttonStyle(.glass(capsule: true))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), style: .panel)
    }

    // MARK: Recording

    private func toggleRecording() {
        if recorder.isArmed {
            recorder.cancelCountdown()
            pendingAppendTarget = nil
            return
        }
        if recorder.isRecording {
            recorder.stop()
        } else {
            pendingAppendTarget = nil
            beginRecording(appendingTo: [])
        }
    }

    private func extend(_ macro: Macro) {
        guard !recorder.isRecording, !recorder.isArmed else { return }
        pendingAppendTarget = macro
        note = "Recording will be added to the end of “\(macro.name)”."
        beginRecording(appendingTo: macro.events)
    }

    private func beginRecording(appendingTo events: [MacroEvent]) {
        recorder.capturesMouseMovement = settings.recordsMouseMovement
        recorder.stopsWithEscape = settings.stopsWithEscape
        recorder.countdownSeconds = settings.recordCountdownSeconds
        recorder.maxDurationSeconds = settings.maxRecordingSeconds
        recorder.ignoresModifierOnlyKeys = settings.ignoresModifierOnlyKeys
        recorder.start(appendingTo: events)
    }

    /// Called the moment recording stops, however it stopped.
    private func finishTake() {
        guard !recorder.liveEvents.isEmpty else {
            pendingAppendTarget = nil
            note = nil
            return
        }

        if let target = pendingAppendTarget {
            var updated = target
            updated.events = recorder.liveEvents
            store.updateMacro(updated)
            note = "“\(target.name)” now has \(updated.events.count) steps."
            pendingAppendTarget = nil
            recorder.discard()
            return
        }

        newMacroName = ""
        activeSheet = .nameNewMacro
    }

    private func saveTake() {
        let macro = Macro(
            name: newMacroName.trimmingCharacters(in: .whitespaces).isEmpty
                ? "Untitled macro"
                : newMacroName.trimmingCharacters(in: .whitespaces),
            events: recorder.liveEvents
        )
        store.addMacro(macro)
        newMacroName = ""
        note = nil
        activeSheet = nil
        recorder.discard()
    }

    // MARK: Playback

    private func play(_ macro: Macro) {
        player.play(macro, options: settings.playbackOptions)
    }

    private func trim(_ macro: Macro) {
        let before = macro.duration
        let trimmed = macro.trimmed(maxGap: 2)
        store.updateMacro(trimmed)
        note = String(
            format: "Trimmed “%@” from %.1fs to %.1fs.",
            macro.name, before, trimmed.duration
        )
    }

    // MARK: Files

    private func export(_ macro: Macro) {
        save(macros: [macro], suggestedName: macro.name)
    }

    private func exportAll() {
        save(macros: store.macros, suggestedName: "MacroGlass macros")
    }

    private func save(macros: [Macro], suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName + ".json"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.message = "Save \(macros.count) macro\(macros.count == 1 ? "" : "s") as JSON"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportData(for: macros)
            try data.write(to: url, options: .atomic)
            note = "Saved to \(url.lastPathComponent)."
        } catch {
            note = "Could not save: \(error.localizedDescription)"
        }
    }

    private func importMacros() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a macro file exported from MacroGlass"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let count = try store.importMacros(from: data)
            note = "Imported \(count) macro\(count == 1 ? "" : "s")."
        } catch {
            note = "That file didn't look like MacroGlass macros."
        }
    }
}

// MARK: - One row

private struct MacroRow: View {
    let macro: Macro
    let tint: Color
    let isPlaying: Bool
    let canPlay: Bool
    let onPlay: () -> Void
    let onExtend: () -> Void
    let onRename: () -> Void
    let onHotkey: () -> Void
    let onInspect: () -> Void
    let onDuplicate: () -> Void
    let onTrim: () -> Void
    let onExport: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(macro.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)

                    if let hotkey = macro.hotkey {
                        Text(hotkey.displayName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .glass(Capsule(), style: .control)
                    }

                    if let notes = macro.notes, !notes.isEmpty {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help(notes)
                    }
                }

                Text("\(macro.events.count) steps · \(String(format: "%.1fs", macro.duration)) · \(macro.breakdown)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button(action: onPlay) {
                Image(systemName: isPlaying ? "waveform" : "play.fill")
            }
            .buttonStyle(.glassIcon(tint: isPlaying ? nil : tint))
            .disabled(!canPlay)
            .help("Play this macro")

            Menu {
                Button("Rename…", action: onRename)
                Button(macro.hotkey == nil ? "Assign a hotkey…" : "Change hotkey…", action: onHotkey)
                Button("Inspect steps…", action: onInspect)
                Divider()
                Button("Extend by recording more", action: onExtend)
                Button("Duplicate", action: onDuplicate)
                Button("Trim long pauses", action: onTrim)
                Divider()
                Button("Move up", action: onMoveUp)
                Button("Move down", action: onMoveDown)
                Divider()
                Button("Export…", action: onExport)
                Button("Copy as AppleScript") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppleScriptExporter.generate(for: macro), forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 26)
            .glass(Circle(), style: .control)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), style: .panel)
    }
}

// MARK: - Sheets

private struct NameMacroSheet: View {
    @Binding var name: String
    let title: String
    let tint: Color
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            TextField("Untitled macro", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glass(RoundedRectangle(cornerRadius: 10, style: .continuous), style: .recessed)

            HStack {
                Button("Discard", action: onCancel)
                    .buttonStyle(.glass(capsule: true))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: onSave)
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(GlassSurface(shape: Rectangle(), style: .window))
    }
}

private struct RenameSheet: View {
    let macro: Macro
    let tint: Color
    var onSave: (String) -> Void
    var onCancel: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename macro")
                .font(.system(size: 13, weight: .semibold))

            TextField(macro.name, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glass(RoundedRectangle(cornerRadius: 10, style: .continuous), style: .recessed)

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass(capsule: true))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") { onSave(draft) }
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(GlassSurface(shape: Rectangle(), style: .window))
        .onAppear { draft = macro.name }
    }
}

// HotkeySheet lives in HotkeySheet.swift — Settings uses it too.
