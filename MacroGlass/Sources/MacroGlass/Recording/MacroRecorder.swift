import Cocoa
import Combine

/// Captures keyboard and mouse events globally (even when the app isn't
/// focused) using a listen-only CGEventTap, and buffers them as
/// timestamped MacroEvents while recording is active.
final class MacroRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var liveEvents: [MacroEvent] = []
    /// Counting down before the tap opens, so you can get to the window
    /// you actually want to record in.
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var elapsed: TimeInterval = 0

    /// Set from Settings before `start()`.
    var capturesMouseMovement = false
    var stopsWithEscape = true
    var countdownSeconds = 0
    /// 0 records until you stop it.
    var maxDurationSeconds = 0
    /// Skips ⌘/⌥/⌃/⇧ presses that aren't part of a combination, which
    /// otherwise pad a recording with steps that do nothing.
    var ignoresModifierOnlyKeys = true

    var isArmed: Bool { countdownRemaining > 0 }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startTime: CFAbsoluteTime = 0
    private var lastMoveTime: CFAbsoluteTime = 0
    private var timeOffset: TimeInterval = 0
    private var countdownTimer: Timer?
    private var tickTimer: Timer?

    private static let escapeKeyCode: UInt16 = 53
    private static let moveThrottle: CFAbsoluteTime = 0.03

    deinit {
        countdownTimer?.invalidate()
        tickTimer?.invalidate()
    }

    // MARK: - Starting

    /// `existing` continues a previous take instead of replacing it, so a
    /// macro can be extended without re-recording the whole thing.
    func start(appendingTo existing: [MacroEvent] = []) {
        guard !isRecording, !isArmed else { return }
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.requestPrompt()
            return
        }

        liveEvents = existing
        timeOffset = existing.last?.timestamp ?? 0

        guard countdownSeconds > 0 else {
            beginCapture()
            return
        }

        countdownRemaining = countdownSeconds
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return }
            countdownRemaining -= 1
            if countdownRemaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.beginCapture()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    /// Cancels an armed countdown before it opens the tap.
    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
        liveEvents.removeAll()
    }

    private func beginCapture() {
        countdownRemaining = 0
        startTime = CFAbsoluteTimeGetCurrent()
        lastMoveTime = 0
        elapsed = 0

        var mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        if capturesMouseMovement {
            mask |= (1 << CGEventType.mouseMoved.rawValue)
            mask |= (1 << CGEventType.leftMouseDragged.rawValue)
        }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let recorder = Unmanaged<MacroRecorder>.fromOpaque(refcon).takeUnretainedValue()
                recorder.handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRecording = true

        startTicking()
    }

    private func startTicking() {
        tickTimer?.invalidate()
        let limit = maxDurationSeconds
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isRecording else { return }
            elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if limit > 0 && elapsed >= Double(limit) {
                self.stop()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Stopping

    /// Stops the tap and returns whatever was captured.
    @discardableResult
    func stop() -> [MacroEvent] {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = 0
        tickTimer?.invalidate()
        tickTimer = nil

        guard isRecording, let tap = eventTap else { return liveEvents }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRecording = false
        return liveEvents
    }

    func discard() {
        liveEvents.removeAll()
        elapsed = 0
        timeOffset = 0
    }

    // MARK: - Capturing

    private func handle(type: CGEventType, event: CGEvent) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedNow = timeOffset + (now - startTime)
        var macroEvent: MacroEvent?

        switch type {
        case .keyDown, .keyUp:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

            // Esc is the panic button, not a recorded keystroke.
            if stopsWithEscape && keyCode == Self.escapeKeyCode {
                if type == .keyDown {
                    DispatchQueue.main.async { self.stop() }
                }
                return
            }

            if ignoresModifierOnlyKeys && KeyCodes.isModifier(keyCode) { return }

            macroEvent = MacroEvent(
                type: type == .keyDown ? .keyDown : .keyUp,
                timestamp: elapsedNow,
                keyCode: keyCode,
                modifiers: MacroEvent.Modifiers(flags: event.flags),
                point: nil,
                scrollDeltaY: nil
            )

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let kind: MacroEvent.Kind = {
                switch type {
                case .leftMouseDown: return .leftMouseDown
                case .leftMouseUp: return .leftMouseUp
                case .rightMouseDown: return .rightMouseDown
                default: return .rightMouseUp
                }
            }()
            macroEvent = MacroEvent(
                type: kind,
                timestamp: elapsedNow,
                keyCode: nil,
                modifiers: nil,
                point: CGPointCodable(event.location),
                scrollDeltaY: nil
            )

        case .mouseMoved, .leftMouseDragged:
            // Throttled: the pointer fires far more often than playback
            // needs, and unthrottled moves bloat a macro badly.
            guard now - lastMoveTime >= Self.moveThrottle else { return }
            lastMoveTime = now
            macroEvent = MacroEvent(
                type: .mouseMoved,
                timestamp: elapsedNow,
                keyCode: nil,
                modifiers: nil,
                point: CGPointCodable(event.location),
                scrollDeltaY: nil
            )

        case .scrollWheel:
            let deltaY = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            macroEvent = MacroEvent(
                type: .scrollWheel,
                timestamp: elapsedNow,
                keyCode: nil,
                modifiers: nil,
                point: nil,
                scrollDeltaY: deltaY
            )

        default:
            break
        }

        if let macroEvent {
            DispatchQueue.main.async {
                self.liveEvents.append(macroEvent)
            }
        }
    }
}
