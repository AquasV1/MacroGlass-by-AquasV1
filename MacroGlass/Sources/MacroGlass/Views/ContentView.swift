import SwiftUI

struct ContentView: View {
    @StateObject private var store = MacroStore()
    @StateObject private var settings = AppSettings()
    @StateObject private var recorder = MacroRecorder()
    @StateObject private var player = MacroPlayer()
    @StateObject private var clicker = AutoClicker()
    @StateObject private var automation = AutomationController()
    @StateObject private var registry = LanguageRegistry()
    @StateObject private var hotkeys = HotkeyCenter()

    /// nil means the chooser is showing.
    @State private var mode: AppMode?
    @State private var selection: AppTab = .record
    @State private var didPickStartupMode = false

    var body: some View {
        Group {
            // `mode` is Optional, and a bare `case .macro:` doesn't match
            // through an Optional — unwrap first rather than writing
            // `.macro?` patterns.
            if let mode {
                switch mode {
                case .macro: macroMode
                case .clicker: clickerMode
                }
            } else {
                ModeChooserView(settings: settings) { chosen in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        self.mode = chosen
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(
            minWidth: 520, idealWidth: 560, maxWidth: 760,
            minHeight: 470, idealHeight: 600, maxHeight: 900
        )
        .environment(\.glassIntensity, settings.glassIntensity)
        .background(windowGlass)
        .background(WindowConfigurator(floatOnTop: settings.floatOnTop))
        .onAppear {
            automation.attach(settings: settings, store: store, registry: registry)
            automation.handleLaunch()
            wireHotkeys()
            refreshHotkeys()

            // Honor "open to" once, on the first appearance only — coming
            // back to the chooser by hand shouldn't bounce straight out
            // of it again.
            if !didPickStartupMode {
                didPickStartupMode = true
                mode = settings.startupMode.appMode
            }
        }
        // Binding a key to a macro, or adding a macro that has one, has to
        // reach the global listener — so does clearing one.
        .onChange(of: store.macros) { _, _ in refreshHotkeys() }
        .onChange(of: settings.panicHotkey) { _, _ in refreshHotkeys() }
        .onChange(of: settings.recordHotkey) { _, _ in refreshHotkeys() }
        .onChange(of: settings.clickerHotkey) { _, _ in refreshHotkeys() }
        // A hotkey you're currently recording should be captured as part of
        // the macro, not swallowed to trigger one.
        .onChange(of: recorder.isRecording) { _, recording in
            hotkeys.isSuspended = recording
        }
    }

    // MARK: Macro mode

    private var macroMode: some View {
        VStack(spacing: 0) {
            header {
                GlassTabBar(
                    selection: $selection,
                    tint: settings.tint,
                    activeTab: player.isPlaying ? .record : nil
                )
            }

            Group {
                switch selection {
                case .record:
                    RecordView(
                        store: store,
                        recorder: recorder,
                        player: player,
                        hotkeys: hotkeys,
                        settings: settings
                    )
                case .script:
                    ScriptView(store: store, settings: settings, registry: registry)
                case .settings:
                    SettingsView(
                        store: store,
                        settings: settings,
                        automation: automation,
                        registry: registry,
                        hotkeys: hotkeys
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Clicker mode

    private var clickerMode: some View {
        VStack(spacing: 0) {
            header {
                HStack(spacing: 6) {
                    Image(systemName: AppMode.clicker.symbol)
                        .font(.system(size: 11, weight: .medium))
                    Text(AppMode.clicker.title)
                        .font(.system(size: 12, weight: .medium))
                    if clicker.isRunning {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glass(Capsule(), style: GlassStyle.control.tinted(settings.tint))
            }

            ClickerView(settings: settings, clicker: clicker, hotkeys: hotkeys)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The top strip both modes share: whatever the mode puts in the
    /// middle, with a way back to the chooser tucked in the corner.
    private func header<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()

            HStack {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
                        mode = nil
                    }
                } label: {
                    Image(systemName: "square.grid.2x2")
                }
                .buttonStyle(.glassIcon())
                .help("Back to the start")
                Spacer()
            }
            .padding(.leading, 18)
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Hotkeys

    private func wireHotkeys() {
        hotkeys.onMacro = { id in
            guard let macro = store.macros.first(where: { $0.id == id }) else { return }
            if player.isPlaying {
                // Pressing the trigger again is the most natural way to
                // ask for it to stop.
                player.stop()
            } else {
                player.play(macro, options: settings.playbackOptions)
            }
        }

        // One key that stops everything, whatever is going on.
        hotkeys.onPanic = {
            player.stop()
            clicker.stop()
            if recorder.isRecording { recorder.stop() }
        }

        hotkeys.onClickerToggle = {
            clicker.toggle(config: settings.clicker)
        }

        hotkeys.onRecordToggle = {
            if recorder.isRecording {
                recorder.stop()
            } else {
                recorder.capturesMouseMovement = settings.recordsMouseMovement
                recorder.stopsWithEscape = settings.stopsWithEscape
                recorder.countdownSeconds = settings.recordCountdownSeconds
                recorder.maxDurationSeconds = settings.maxRecordingSeconds
                recorder.ignoresModifierOnlyKeys = settings.ignoresModifierOnlyKeys
                recorder.start()
            }
        }
    }

    private func refreshHotkeys() {
        hotkeys.update(
            macros: store.macros,
            panic: settings.panicHotkey,
            recordToggle: settings.recordHotkey,
            clickerToggle: settings.clickerHotkey
        )
    }

    private var windowGlass: some View {
        ZStack {
            GlassSurface(shape: Rectangle(), style: .window)

            // A soft light source in the top-left corner, so the slab reads
            // as lit rather than flat.
            RadialGradient(
                colors: [.white.opacity(0.11), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 430
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}
