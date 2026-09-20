import Cocoa
import Combine

/// Global hotkeys: press a combination anywhere — in a game, in a browser,
/// with MacroGlass hidden — and the macro bound to it plays.
///
/// This tap is a *default* tap rather than a listen-only one, so a matched
/// combination is swallowed instead of also reaching the app in front. That
/// is the difference between F1 playing your macro and F1 playing your
/// macro while the game also does whatever F1 normally does.
final class HotkeyCenter: ObservableObject {
    @Published private(set) var isListening = false
    /// Set when the tap couldn't be created, so Settings can say why.
    @Published private(set) var failureReason: String?

    /// Handed in by ContentView once the other objects exist.
    var onMacro: ((UUID) -> Void)?
    var onPanic: (() -> Void)?
    var onRecordToggle: (() -> Void)?
    var onClickerToggle: (() -> Void)?

    /// Raised while recording, so binding a hotkey to a macro doesn't mean
    /// you can never record that key again.
    var isSuspended = false

    private var macroBindings: [(id: UUID, hotkey: MacroHotkey)] = []
    private var panicHotkey: MacroHotkey?
    private var recordHotkey: MacroHotkey?
    private var clickerHotkey: MacroHotkey?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    deinit {
        teardown()
    }

    // MARK: - Registration

    /// Rebuilt whenever macros change or the hotkey settings move. Cheap
    /// enough to call often: the tap is only torn down when it has to be.
    func update(
        macros: [Macro],
        panic: MacroHotkey?,
        recordToggle: MacroHotkey?,
        clickerToggle: MacroHotkey?
    ) {
        macroBindings = macros.compactMap { macro in
            macro.hotkey.map { (id: macro.id, hotkey: $0) }
        }
        panicHotkey = panic
        recordHotkey = recordToggle
        clickerHotkey = clickerToggle

        let wanted = !macroBindings.isEmpty
            || panic != nil
            || recordToggle != nil
            || clickerToggle != nil
        if wanted {
            startIfNeeded()
        } else {
            teardown()
        }
    }

    /// Every combination currently spoken for, so the recorder sheet can
    /// warn about a clash instead of silently stealing it.
    func conflict(for hotkey: MacroHotkey, excluding macroID: UUID?) -> String? {
        if let panicHotkey, panicHotkey == hotkey { return "the panic stop" }
        if let recordHotkey, recordHotkey == hotkey { return "record start/stop" }
        if let clickerHotkey, clickerHotkey == hotkey { return "the auto clicker" }
        if macroBindings.contains(where: { $0.hotkey == hotkey && $0.id != macroID }) {
            return "another macro"
        }
        return nil
    }

    // MARK: - The tap

    private func startIfNeeded() {
        guard eventTap == nil else { return }
        guard AccessibilityPermission.isTrusted else {
            failureReason = "Accessibility access is needed before hotkeys can be watched for."
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(refcon).takeUnretainedValue()
            return center.handle(type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            failureReason = "macOS refused the event tap. Re-granting Accessibility usually fixes it."
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            failureReason = "Could not attach the hotkey listener to the run loop."
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isListening = true
        failureReason = nil
    }

    private func teardown() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isListening = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that takes too long, or across a fast user
        // switch. Neither is fatal — turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, !isSuspended else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard !KeyCodes.isModifier(keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        let flags = event.flags

        if let panicHotkey, panicHotkey.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onPanic?() }
            return nil
        }

        if let recordHotkey, recordHotkey.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onRecordToggle?() }
            return nil
        }

        if let clickerHotkey, clickerHotkey.matches(keyCode: keyCode, flags: flags) {
            DispatchQueue.main.async { [weak self] in self?.onClickerToggle?() }
            return nil
        }

        if let binding = macroBindings.first(where: { $0.hotkey.matches(keyCode: keyCode, flags: flags) }) {
            let id = binding.id
            DispatchQueue.main.async { [weak self] in self?.onMacro?(id) }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Capturing a combination in the UI

/// Watches the next keystroke inside the app so a hotkey can be assigned by
/// pressing it. A local monitor is right here rather than the global tap:
/// it only fires while MacroGlass is frontmost, it consumes the key so the
/// editor doesn't also receive it, and it needs no extra permission.
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var captured: MacroHotkey?

    private var monitor: Any?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func begin() {
        guard !isCapturing else { return }
        isCapturing = true
        captured = nil

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // Esc backs out without assigning anything.
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            guard !KeyCodes.isModifier(event.keyCode) else { return nil }

            var modifiers = MacroEvent.Modifiers()
            modifiers.command = event.modifierFlags.contains(.command)
            modifiers.option = event.modifierFlags.contains(.option)
            modifiers.control = event.modifierFlags.contains(.control)
            modifiers.shift = event.modifierFlags.contains(.shift)

            self.captured = MacroHotkey(keyCode: event.keyCode, modifiers: modifiers)
            self.stopMonitoring()
            self.isCapturing = false
            return nil
        }
    }

    func cancel() {
        stopMonitoring()
        isCapturing = false
        captured = nil
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
