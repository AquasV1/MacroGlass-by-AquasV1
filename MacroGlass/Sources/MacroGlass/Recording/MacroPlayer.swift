import Cocoa
import Combine

/// Replays a saved Macro by posting synthetic CGEvents, honoring the
/// original timing between steps (scaled by `speed`), after an optional
/// countdown so you have time to switch windows.
///
/// An object rather than a free function, because playback now needs to be
/// watchable (which macro, how far through) and — more importantly —
/// stoppable. A macro that loops forever with no way out is a macro that
/// makes you force-quit.
final class MacroPlayer: ObservableObject {

    struct Options {
        var speed: Double = 1
        var repeatCount: Int = 1
        var loopsForever: Bool = false
        var countdown: Int = 0
        /// Randomizes each gap by ±this percentage. Perfectly even timing
        /// is the most obvious thing about a replayed macro.
        var jitterPercent: Double = 0
        var restoresCursor: Bool = true
        var pauseBetweenLoops: Double = 0
    }

    @Published private(set) var playingMacroID: UUID?
    @Published private(set) var playingMacroName: String = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentLoop: Int = 0
    @Published private(set) var totalLoops: Int = 0
    @Published private(set) var countdownRemaining: Int = 0

    var isPlaying: Bool { playingMacroID != nil }

    private var token: Token?
    /// Bumped on every run, so a thread winding down from the previous one
    /// can't clear the state a newer run just set.
    private var generation = 0

    // MARK: - Control

    func play(_ macro: Macro, options: Options, completion: (() -> Void)? = nil) {
        guard !isPlaying else { return }
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.requestPrompt()
            completion?()
            return
        }
        guard !macro.events.isEmpty else {
            completion?()
            return
        }

        let token = Token()
        self.token = token
        generation += 1
        let run = generation

        playingMacroID = macro.id
        playingMacroName = macro.name
        progress = 0
        currentLoop = 1
        totalLoops = options.loopsForever ? 0 : max(1, options.repeatCount)
        countdownRemaining = options.countdown

        let events = macro.events
        let steps = max(1, events.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Countdown, a second at a time so it can be cancelled and so
            // the UI can show it ticking down.
            var remaining = options.countdown
            while remaining > 0 && !token.isCancelled {
                let tick = remaining
                DispatchQueue.main.async { self?.report(countdown: tick, run: run) }
                Thread.sleep(forTimeInterval: 1)
                remaining -= 1
            }
            DispatchQueue.main.async { self?.report(countdown: 0, run: run) }

            let savedCursor = CGEvent(source: nil)?.location
            var loop = 0

            while !token.isCancelled {
                loop += 1
                let currentLoopIndex = loop
                DispatchQueue.main.async { self?.report(loop: currentLoopIndex, run: run) }

                var previousTimestamp: TimeInterval = 0
                for (index, event) in events.enumerated() {
                    if token.isCancelled { break }

                    var delay = (event.timestamp - previousTimestamp) / max(options.speed, 0.01)
                    if options.jitterPercent > 0, delay > 0 {
                        let spread = delay * (options.jitterPercent / 100)
                        delay += Double.random(in: -spread...spread)
                    }
                    if delay > 0 {
                        Self.interruptibleSleep(delay, token: token)
                    }
                    previousTimestamp = event.timestamp

                    if token.isCancelled { break }
                    Self.post(event)

                    let fraction = Double(index + 1) / Double(steps)
                    DispatchQueue.main.async { self?.report(progress: fraction, run: run) }
                }

                if !options.loopsForever && loop >= max(1, options.repeatCount) { break }
                if options.pauseBetweenLoops > 0 {
                    Self.interruptibleSleep(options.pauseBetweenLoops, token: token)
                }
            }

            if options.restoresCursor, let savedCursor, !token.isCancelled {
                let source = CGEventSource(stateID: .hidSystemState)
                CGEvent(
                    mouseEventSource: source,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: savedCursor,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
            }

            let wasCancelled = token.isCancelled
            DispatchQueue.main.async {
                self?.finish(run: run)
                completion?()
                if !wasCancelled {
                    NotificationCenter.default.post(name: .macroPlaybackFinished, object: nil)
                }
            }
        }
    }

    /// The panic button. Safe to call when nothing is playing.
    func stop() {
        token?.cancel()
        token = nil
        generation += 1
        clear()
    }

    // MARK: - State, always on the main thread

    private func report(progress value: Double, run: Int) {
        guard run == generation else { return }
        progress = value
    }

    private func report(loop: Int, run: Int) {
        guard run == generation else { return }
        currentLoop = loop
    }

    private func report(countdown: Int, run: Int) {
        guard run == generation else { return }
        countdownRemaining = countdown
    }

    private func finish(run: Int) {
        guard run == generation else { return }
        token = nil
        clear()
    }

    private func clear() {
        playingMacroID = nil
        playingMacroName = ""
        progress = 0
        currentLoop = 0
        totalLoops = 0
        countdownRemaining = 0
    }

    // MARK: - Timing

    /// Sleeping through a five-second gap in one go would make Stop feel
    /// broken, so long waits are chopped into slices that check the flag.
    private static func interruptibleSleep(_ duration: TimeInterval, token: Token) {
        let slice: TimeInterval = 0.05
        var remaining = duration
        while remaining > 0 && !token.isCancelled {
            let step = min(slice, remaining)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
        }
    }

    // MARK: - Posting

    private static func post(_ event: MacroEvent) {
        let source = CGEventSource(stateID: .hidSystemState)

        switch event.type {
        case .keyDown, .keyUp:
            guard let keyCode = event.keyCode else { return }
            let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: event.type == .keyDown)
            cgEvent?.flags = event.modifiers?.cgEventFlags ?? []
            cgEvent?.post(tap: .cghidEventTap)

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            guard let point = event.point else { return }
            let mouseType: CGEventType = {
                switch event.type {
                case .leftMouseDown: return .leftMouseDown
                case .leftMouseUp: return .leftMouseUp
                case .rightMouseDown: return .rightMouseDown
                default: return .rightMouseUp
                }
            }()
            let button: CGMouseButton = (event.type == .rightMouseDown || event.type == .rightMouseUp) ? .right : .left
            let cgEvent = CGEvent(mouseEventSource: source, mouseType: mouseType, mouseCursorPosition: point.cgPoint, mouseButton: button)
            cgEvent?.post(tap: .cghidEventTap)

        case .mouseMoved:
            guard let point = event.point else { return }
            let cgEvent = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point.cgPoint, mouseButton: .left)
            cgEvent?.post(tap: .cghidEventTap)

        case .scrollWheel:
            guard let deltaY = event.scrollDeltaY else { return }
            let cgEvent = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0)
            cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Set on the main thread, read from the playback thread.
    private final class Token: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
}
