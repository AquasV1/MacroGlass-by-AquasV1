import SwiftUI
import AppKit

/// The auto clicker. Clicks or keystrokes on a timer, anywhere on screen,
/// with the things that make one actually usable: a global hotkey so you
/// don't have to alt-tab to start it, randomized timing so it isn't a
/// metronome, and a way out that doesn't involve force-quitting.
struct ClickerView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var clicker: AutoClicker
    @ObservedObject var hotkeys: HotkeyCenter

    @StateObject private var picker = ScreenPointPicker()
    @StateObject private var keyRecorder = HotkeyRecorder()
    @State private var showsHotkeySheet = false

    private var config: ClickerConfig { settings.clicker }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                runCard
                whatCard
                rateCard
                timerCard
                whereCard
                safetyCard
                hotkeyCard
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showsHotkeySheet) {
            HotkeySheet(
                title: "Start and stop the clicker",
                current: settings.clickerHotkey,
                tint: settings.tint,
                conflictCheck: { hotkeys.conflict(for: $0, excluding: nil) },
                onSave: { hotkey in
                    settings.clickerHotkey = hotkey
                    showsHotkeySheet = false
                },
                onCancel: { showsHotkeySheet = false }
            )
        }
        .onChange(of: keyRecorder.captured) { _, captured in
            guard let captured else { return }
            settings.clicker.keyCode = captured.keyCode
            settings.clicker.keyModifiers = captured.modifiers
        }
    }

    // MARK: Run

    private var runCard: some View {
        VStack(spacing: 10) {
            Button {
                clicker.clearProblem()
                clicker.toggle(config: config)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: runSymbol)
                    Text(runLabel)
                }
            }
            .buttonStyle(.glass(
                tint: clicker.isRunning ? .red : settings.tint,
                capsule: true,
                fullWidth: true
            ))

            HStack(spacing: 0) {
                stat("Sent", value: "\(clicker.clicksSent)")
                divider
                stat("Rate", value: String(format: "%.1f/s", config.clicksPerSecond))
                divider
                stat(clicker.isRunning ? clicker.phase.label : "Ready", value: liveValue)
            }

            footerLine
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), style: .panel)
    }

    private var liveValue: String {
        if clicker.isCountingDown { return "\(clicker.countdownRemaining)s" }
        if clicker.phaseRemaining > 0 { return "\(clicker.phaseRemaining)s" }
        if clicker.isRunning && clicker.elapsed > 0 { return String(format: "%.0fs", clicker.elapsed) }
        return "—"
    }

    @ViewBuilder
    private var footerLine: some View {
        if let problem = clicker.problem {
            caption(problem).foregroundStyle(.orange)
        } else if let ended = clicker.stoppedBecause, !clicker.isRunning {
            caption("Stopped — \(ended)")
        } else {
            caption(config.summary)
        }
    }

    private var runSymbol: String {
        if clicker.isCountingDown { return "timer" }
        return clicker.isRunning ? "stop.fill" : "cursorarrow.click"
    }

    private var runLabel: String {
        if clicker.isCountingDown { return "Starting in \(clicker.countdownRemaining)…" }
        if clicker.isRunning { return "Stop" }
        return "Start clicking"
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 1, height: 26)
    }

    // MARK: What it sends

    private var whatCard: some View {
        card("What it sends") {
            HStack(spacing: 8) {
                ForEach(ClickerConfig.Mode.allCases) { mode in
                    Button(mode.label) { settings.clicker.mode = mode }
                        .buttonStyle(.glass(tint: config.mode == mode ? settings.tint : nil, capsule: true))
                }
                Spacer()
            }

            if config.mode == .click {
                row("Button") {
                    menuPill(config.button.label) {
                        ForEach(ClickerConfig.Button.allCases) { button in
                            Button(button.label) { settings.clicker.button = button }
                        }
                    }
                }

                row("Hold modifiers") {
                    menuPill(modifierLabel(config.clickModifiers)) {
                        modifierToggle("⌘ Command", keyPath: \.command)
                        modifierToggle("⌥ Option", keyPath: \.option)
                        modifierToggle("⌃ Control", keyPath: \.control)
                        modifierToggle("⇧ Shift", keyPath: \.shift)
                        Divider()
                        Button("None") { settings.clicker.clickModifiers = MacroEvent.Modifiers() }
                    }
                }

                toggleRow("Double-click", isOn: Binding(
                    get: { config.isDoubleClick },
                    set: { settings.clicker.isDoubleClick = $0 }
                ))
            } else {
                row("Key") {
                    Button(keyRecorder.isCapturing ? "Press a key…" : config.keyDescription) {
                        keyRecorder.begin()
                    }
                    .buttonStyle(.glass(tint: keyRecorder.isCapturing ? settings.tint : nil, capsule: true))
                }
                caption("Hold a modifier while pressing to include it — ⇧Space, ⌘1 and so on.")
            }

            row("Hold each press for") {
                stepperPill(
                    config.holdMilliseconds == 0 ? "Instant" : "\(config.holdMilliseconds) ms",
                    onDown: { settings.clicker.holdMilliseconds = max(0, config.holdMilliseconds - 10) },
                    onUp: { settings.clicker.holdMilliseconds = min(2000, config.holdMilliseconds + 10) }
                )
            }
        }
    }

    private func modifierLabel(_ modifiers: MacroEvent.Modifiers) -> String {
        var label = ""
        if modifiers.control { label += "⌃" }
        if modifiers.option { label += "⌥" }
        if modifiers.shift { label += "⇧" }
        if modifiers.command { label += "⌘" }
        return label.isEmpty ? "None" : label
    }

    private func modifierToggle(_ title: String, keyPath: WritableKeyPath<MacroEvent.Modifiers, Bool>) -> some View {
        Button {
            settings.clicker.clickModifiers[keyPath: keyPath].toggle()
        } label: {
            Text("\(config.clickModifiers[keyPath: keyPath] ? "✓ " : "")\(title)")
        }
    }

    // MARK: Rate

    private var rateCard: some View {
        card("How fast") {
            HStack(spacing: 8) {
                Text("Rate").font(.system(size: 12.5))

                Button("ms") { settings.clicker.entersRateAsCPS = false }
                    .buttonStyle(.glass(
                        tint: config.entersRateAsCPS ? nil : settings.tint,
                        capsule: true,
                        horizontalPadding: 9
                    ))
                Button("/sec") { settings.clicker.entersRateAsCPS = true }
                    .buttonStyle(.glass(
                        tint: config.entersRateAsCPS ? settings.tint : nil,
                        capsule: true,
                        horizontalPadding: 9
                    ))

                Spacer(minLength: 6)

                stepperPill(rateLabel, onDown: { nudgeRate(down: true) }, onUp: { nudgeRate(down: false) })
            }

            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { preset in
                    Button(presetLabel(preset)) { settings.clicker.intervalMilliseconds = preset }
                        .buttonStyle(.glass(
                            tint: config.effectiveInterval == preset ? settings.tint : nil,
                            capsule: true,
                            horizontalPadding: 8
                        ))
                }
                Spacer()
            }

            if config.isAtRateCap {
                rateCapNote
            }

            sliderRow(
                "Randomize timing",
                value: Binding(
                    get: { config.jitterPercent },
                    set: { settings.clicker.jitterPercent = $0 }
                ),
                range: 0...60,
                display: config.jitterPercent == 0 ? "Off" : String(format: "±%.0f%%", config.jitterPercent)
            )

            row("Clicks per burst") {
                stepperPill(
                    config.burstCount == 1 ? "One" : "\(config.burstCount)",
                    onDown: { settings.clicker.burstCount = max(1, config.burstCount - 1) },
                    onUp: { settings.clicker.burstCount = min(100, config.burstCount + 1) }
                )
            }

            if config.burstCount > 1 {
                row("Gap inside a burst") {
                    stepperPill(
                        "\(config.burstGapMilliseconds) ms",
                        onDown: { settings.clicker.burstGapMilliseconds = max(1, config.burstGapMilliseconds - 5) },
                        onUp: { settings.clicker.burstGapMilliseconds = min(5000, config.burstGapMilliseconds + 5) }
                    )
                }
                caption("\(config.burstCount) clicks back to back, then the rate above before the next burst.")
            } else if config.jitterPercent > 0 {
                caption(String(format: "Gaps land between %.0f and %.0f ms.",
                               config.jitterRange.lowerBound, config.jitterRange.upperBound))
            } else {
                caption("A dead-even click train is the most obvious thing about an auto clicker. A little randomness costs nothing.")
            }
        }
    }

    /// The honest version of "why can't I go faster".
    private var rateCapNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
                .padding(.top, 1)
            Text("\(ClickerConfig.maxClicksPerSecond) a second is the cap. Unfortunately that's a macOS limit, not one MacroGlass picked: the system coalesces synthetic events arriving faster than about one a millisecond, so the extra clicks get posted and the app you're aiming at never sees them — and the thread pacing them can't reliably sleep for less than a millisecond either.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 10, style: .continuous), style: .recessed)
    }

    private var rateLabel: String {
        if config.entersRateAsCPS {
            let cps = config.rawClicksPerSecond
            return cps >= 10
                ? String(format: "%.0f/s", cps)
                : String(format: "%.1f/s", cps)
        }
        return "\(config.effectiveInterval) ms"
    }

    private var presets: [Int] {
        [1, 10, 50, 100, 250, 1000]
    }

    private func presetLabel(_ interval: Int) -> String {
        config.entersRateAsCPS ? "\(1000 / max(1, interval))/s" : "\(interval)"
    }

    private func nudgeRate(down: Bool) {
        if config.entersRateAsCPS {
            let current = config.rawClicksPerSecond
            let step: Double = current >= 100 ? 50 : (current >= 20 ? 10 : 1)
            settings.clicker.setClicksPerSecond(down ? current - step : current + step)
        } else {
            let current = config.effectiveInterval
            let step: Int
            switch current {
            case ..<20: step = 1
            case ..<100: step = 5
            case ..<1000: step = 25
            case ..<10_000: step = 250
            default: step = 1000
            }
            settings.clicker.intervalMilliseconds = min(
                ClickerConfig.maxIntervalMilliseconds,
                max(ClickerConfig.minIntervalMilliseconds, down ? current - step : current + step)
            )
        }
    }

    // MARK: Timer

    private var timerCard: some View {
        card("Timer") {
            row("Wait before starting") {
                stepperPill(
                    config.startDelaySeconds == 0 ? "None" : "\(config.startDelaySeconds)s",
                    onDown: { settings.clicker.startDelaySeconds = max(0, config.startDelaySeconds - 1) },
                    onUp: { settings.clicker.startDelaySeconds = min(300, config.startDelaySeconds + 1) }
                )
            }

            row("Stop") {
                menuPill(config.limit.label) {
                    ForEach(ClickerConfig.Limit.allCases) { limit in
                        Button(limit.label) { settings.clicker.limit = limit }
                    }
                }
            }

            switch config.limit {
            case .forever:
                caption("The hotkey below, the Stop button, or the panic key will all end it.")
            case .count:
                row("After") {
                    stepperPill(
                        "\(config.clickCount)",
                        onDown: { settings.clicker.clickCount = max(1, config.clickCount - countStep) },
                        onUp: { settings.clicker.clickCount = min(10_000_000, config.clickCount + countStep) }
                    )
                }
                caption("About \(ClickerConfig.durationLabel(estimatedSeconds)) at this rate.")
            case .duration:
                row("After") {
                    stepperPill(
                        ClickerConfig.durationLabel(config.durationSeconds),
                        onDown: { settings.clicker.durationSeconds = max(1, config.durationSeconds - durationStep) },
                        onUp: { settings.clicker.durationSeconds = min(86_400, config.durationSeconds + durationStep) }
                    )
                }
                caption(String(format: "Roughly %.0f clicks at this rate.",
                               Double(config.durationSeconds) * config.clicksPerSecond))
            }

            Divider().opacity(0.25)

            toggleRow("Work in cycles", isOn: Binding(
                get: { config.usesCycles },
                set: { settings.clicker.usesCycles = $0 }
            ))

            if config.usesCycles {
                row("Click for") {
                    stepperPill(
                        ClickerConfig.durationLabel(config.cycleOnSeconds),
                        onDown: { settings.clicker.cycleOnSeconds = max(1, config.cycleOnSeconds - 5) },
                        onUp: { settings.clicker.cycleOnSeconds = min(3600, config.cycleOnSeconds + 5) }
                    )
                }
                row("Then rest for") {
                    stepperPill(
                        ClickerConfig.durationLabel(config.cycleOffSeconds),
                        onDown: { settings.clicker.cycleOffSeconds = max(1, config.cycleOffSeconds - 5) },
                        onUp: { settings.clicker.cycleOffSeconds = min(3600, config.cycleOffSeconds + 5) }
                    )
                }
                caption("Clicks for \(ClickerConfig.durationLabel(config.cycleOnSeconds)), pauses for \(ClickerConfig.durationLabel(config.cycleOffSeconds)), over and over. The stat panel shows which phase it's in and how long is left.")
            } else {
                caption("Cycles are for anything with a cooldown — click through a rotation, wait for it to come back, go again.")
            }
        }
    }

    private var countStep: Int {
        switch config.clickCount {
        case ..<100: return 10
        case ..<1000: return 50
        case ..<10_000: return 500
        default: return 5000
        }
    }

    private var durationStep: Int {
        switch config.durationSeconds {
        case ..<60: return 5
        case ..<600: return 30
        case ..<3600: return 300
        default: return 1800
        }
    }

    private var estimatedSeconds: Int {
        let rate = config.clicksPerSecond
        guard rate > 0 else { return 0 }
        return Int((Double(config.clickCount) / rate).rounded())
    }

    // MARK: Where

    private var whereCard: some View {
        card("Where it clicks") {
            row("Target") {
                menuPill(config.target.label) {
                    ForEach(ClickerConfig.Target.allCases) { target in
                        Button(target.label) { settings.clicker.target = target }
                    }
                }
            }

            switch config.target {
            case .cursor:
                caption("Clicks land wherever you leave the pointer, so you can still move it around mid-run.")

            case .point:
                pointRow(
                    "Point",
                    point: config.point.cgPoint,
                    slot: "point",
                    onPick: { settings.clicker.point = CGPointCodable($0) }
                )
                caption("Pick moves the pointer nowhere — it counts down, then takes wherever your pointer is sitting.")

            case .region:
                pointRow(
                    "Corner 1",
                    point: config.regionStart.cgPoint,
                    slot: "start",
                    onPick: { settings.clicker.regionStart = CGPointCodable($0) }
                )
                pointRow(
                    "Corner 2",
                    point: config.regionEnd.cgPoint,
                    slot: "end",
                    onPick: { settings.clicker.regionEnd = CGPointCodable($0) }
                )
                caption(config.hasRegion
                        ? String(format: "Clicks land at random inside a %.0f × %.0f box.",
                                 config.regionRect.width, config.regionRect.height)
                        : "Set both corners — every click lands somewhere at random between them.")
            }

            if config.target != .cursor {
                toggleRow("Put the pointer back afterwards", isOn: Binding(
                    get: { config.restoresCursor },
                    set: { settings.clicker.restoresCursor = $0 }
                ))
            }
        }
    }

    private func pointRow(_ title: String, point: CGPoint, slot: String, onPick: @escaping (CGPoint) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12.5))
            Spacer(minLength: 6)
            Text(point == .zero ? "Not set" : String(format: "%.0f, %.0f", point.x, point.y))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(point == .zero ? Color.secondary : Color.primary)
            Button(picker.slot == slot ? "\(picker.countdown)…" : "Pick") {
                if picker.isPicking {
                    picker.cancel()
                } else {
                    picker.pick(slot: slot, seconds: 3, completion: onPick)
                }
            }
            .buttonStyle(.glass(tint: picker.slot == slot ? settings.tint : nil, capsule: true))
        }
    }

    // MARK: Safety

    private var safetyCard: some View {
        card("Safety") {
            toggleRow("Stop if I move the pointer", isOn: Binding(
                get: { config.stopsIfPointerMoves },
                set: { settings.clicker.stopsIfPointerMoves = $0 }
            ))

            if config.stopsIfPointerMoves {
                sliderRow(
                    "How far counts as moved",
                    value: Binding(
                        get: { config.pointerMoveTolerance },
                        set: { settings.clicker.pointerMoveTolerance = $0 }
                    ),
                    range: 5...300,
                    display: String(format: "%.0f px", config.pointerMoveTolerance)
                )
            }

            toggleRow("Beep when it starts and stops", isOn: Binding(
                get: { config.beepsOnStartAndStop },
                set: { settings.clicker.beepsOnStartAndStop = $0 }
            ))

            caption(config.stopsIfPointerMoves
                    ? "Nothing here moves the pointer between clicks, so any movement across a gap was your hand — grabbing the mouse is enough to end the run."
                    : "Worth turning on. Grabbing the mouse becomes the way out, which beats hunting for the hotkey while something is clicking.")
        }
    }

    // MARK: Hotkey

    private var hotkeyCard: some View {
        card("Hotkey") {
            HStack(spacing: 8) {
                Text("Start / stop").font(.system(size: 12.5))
                Spacer(minLength: 6)
                Text(settings.clickerHotkey?.displayName ?? "None")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(settings.clickerHotkey == nil ? Color.secondary : Color.primary)
                Button(settings.clickerHotkey == nil ? "Set…" : "Change…") { showsHotkeySheet = true }
                    .buttonStyle(.glass(tint: settings.clickerHotkey == nil ? settings.tint : nil, capsule: true))
            }
            caption("Set one. Otherwise starting the clicker means leaving the window you want it to click in, and the start delay is doing all the work.")
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
                .frame(minWidth: 58)
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
}
