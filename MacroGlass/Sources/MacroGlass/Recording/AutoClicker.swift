import Cocoa
import Combine

// MARK: - Configuration

/// Everything the clicker needs, in one Codable lump so AppSettings can
/// store it as a single blob instead of thirty loose keys.
struct ClickerConfig: Codable, Hashable {

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case click
        case keystroke
        var id: String { rawValue }
        var label: String { self == .click ? "Click" : "Keystroke" }
    }

    enum Button: String, Codable, CaseIterable, Identifiable {
        case left
        case right
        case middle
        var id: String { rawValue }
        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            case .middle: return "Middle"
            }
        }
    }

    enum Target: String, Codable, CaseIterable, Identifiable {
        case cursor
        case point
        case region
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cursor: return "Wherever the pointer is"
            case .point: return "A fixed point"
            case .region: return "Anywhere in a box"
            }
        }
    }

    enum Limit: String, Codable, CaseIterable, Identifiable {
        case forever
        case count
        case duration
        var id: String { rawValue }
        var label: String {
            switch self {
            case .forever: return "Until I stop it"
            case .count: return "A set number"
            case .duration: return "For a while"
            }
        }
    }

    // MARK: The ceiling
    //
    // One millisecond between events, so a thousand a second. This is
    // macOS's limit rather than a number picked here, for two reasons that
    // both bite well before you'd notice: the thread pacing the events
    // can't reliably sleep for less than a millisecond, and the window
    // server coalesces synthetic events arriving faster than that — they
    // get posted, and the app you're aiming at never sees them.

    static let maxClicksPerSecond = 1000
    static let minIntervalMilliseconds = 1
    static let maxIntervalMilliseconds = 600_000

    // MARK: Stored

    var mode: Mode = .click
    var intervalMilliseconds: Int = 100
    /// Whether the rate is edited as clicks-per-second or milliseconds.
    var entersRateAsCPS: Bool = false
    /// Nudges every gap at random. A perfectly even click train is the
    /// single most obvious thing about an auto-clicker.
    var jitterPercent: Double = 0
    var button: Button = .left
    var isDoubleClick: Bool = false
    /// Held down for every click — ⇧-click, ⌘-click and so on.
    var clickModifiers: MacroEvent.Modifiers = MacroEvent.Modifiers()

    // Bursts: several clicks back to back, then the normal interval.
    var burstCount: Int = 1
    var burstGapMilliseconds: Int = 20

    // Work / rest cycles.
    var usesCycles: Bool = false
    var cycleOnSeconds: Int = 30
    var cycleOffSeconds: Int = 10

    var target: Target = .cursor
    var point: CGPointCodable = CGPointCodable(CGPoint.zero)
    var regionStart: CGPointCodable = CGPointCodable(CGPoint.zero)
    var regionEnd: CGPointCodable = CGPointCodable(CGPoint.zero)

    var limit: Limit = .forever
    var clickCount: Int = 100
    var durationSeconds: Int = 30
    var startDelaySeconds: Int = 3
    /// How long the button or key is held down for each press.
    var holdMilliseconds: Int = 0
    var keyCode: UInt16 = 49          // Space
    var keyModifiers: MacroEvent.Modifiers = MacroEvent.Modifiers()
    /// Puts the pointer back when it's finished moving it around.
    var restoresCursor: Bool = true
    /// Bail out if the pointer is moved by hand — the usual way you want
    /// to stop something that's clicking in a game.
    var stopsIfPointerMoves: Bool = false
    var pointerMoveTolerance: Double = 40
    /// An audible cue, because you're looking at the game, not at this.
    var beepsOnStartAndStop: Bool = false

    // MARK: Derived

    var effectiveInterval: Int {
        min(Self.maxIntervalMilliseconds, max(Self.minIntervalMilliseconds, intervalMilliseconds))
    }

    /// Clicks per second counting bursts, which is the number that
    /// actually matters when a burst is more than one.
    var clicksPerSecond: Double {
        let burst = max(1, burstCount)
        let cycleMilliseconds = Double(effectiveInterval)
            + Double(burst - 1) * Double(max(0, burstGapMilliseconds))
        guard cycleMilliseconds > 0 else { return 0 }
        return Double(burst) * 1000 / cycleMilliseconds
    }

    var isAtRateCap: Bool {
        effectiveInterval <= Self.minIntervalMilliseconds
    }

    /// Setting the rate directly, clamped to the ceiling above.
    mutating func setClicksPerSecond(_ rate: Double) {
        let clamped = min(Double(Self.maxClicksPerSecond), max(0.01, rate))
        intervalMilliseconds = max(
            Self.minIntervalMilliseconds,
            min(Self.maxIntervalMilliseconds, Int((1000 / clamped).rounded()))
        )
    }

    var rawClicksPerSecond: Double {
        1000 / Double(effectiveInterval)
    }

    var jitterRange: ClosedRange<Double> {
        let base = Double(effectiveInterval)
        let spread = base * (jitterPercent / 100)
        return (base - spread)...(base + spread)
    }

    var totalClicksPerCycle: Int { max(1, burstCount) }

    var summary: String {
        var parts: [String] = []
        if mode == .click {
            var prefix = ""
            if clickModifiers.control { prefix += "⌃" }
            if clickModifiers.option { prefix += "⌥" }
            if clickModifiers.shift { prefix += "⇧" }
            if clickModifiers.command { prefix += "⌘" }
            parts.append("\(prefix)\(button.label)\(isDoubleClick ? " double" : "") click")
        } else {
            parts.append(keyDescription)
        }
        if burstCount > 1 { parts.append("×\(burstCount) bursts") }
        parts.append(String(format: "%.1f/sec", clicksPerSecond))
        if jitterPercent > 0 { parts.append(String(format: "±%.0f%%", jitterPercent)) }
        if usesCycles { parts.append("\(cycleOnSeconds)s on / \(cycleOffSeconds)s off") }
        switch limit {
        case .forever: break
        case .count: parts.append("\(clickCount)×")
        case .duration: parts.append(Self.durationLabel(durationSeconds))
        }
        return parts.joined(separator: " · ")
    }

    var keyDescription: String {
        var prefix = ""
        if keyModifiers.control { prefix += "⌃" }
        if keyModifiers.option { prefix += "⌥" }
        if keyModifiers.shift { prefix += "⇧" }
        if keyModifiers.command { prefix += "⌘" }
        return prefix + KeyCodes.name(for: keyCode)
    }

    var regionRect: CGRect {
        let a = regionStart.cgPoint
        let b = regionEnd.cgPoint
        return CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    var hasRegion: Bool {
        regionRect.width > 1 && regionRect.height > 1
    }

    /// "45s", "3m 20s", "2h 5m" — seconds get unreadable past a minute.
    static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let m = seconds / 60, s = seconds % 60
            return s == 0 ? "\(m)m" : "\(m)m \(s)s"
        }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    // MARK: Codable
    //
    // Hand-written so that adding a setting doesn't throw away everything
    // already saved. Swift's synthesized decoder ignores default values
    // and throws the moment a key is missing, which for a blob like this
    // means one new field silently resets every other one.

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, intervalMilliseconds, entersRateAsCPS, jitterPercent
        case button, isDoubleClick, clickModifiers
        case burstCount, burstGapMilliseconds
        case usesCycles, cycleOnSeconds, cycleOffSeconds
        case target, point, regionStart, regionEnd
        case limit, clickCount, durationSeconds, startDelaySeconds
        case holdMilliseconds, keyCode, keyModifiers
        case restoresCursor, stopsIfPointerMoves, pointerMoveTolerance
        case beepsOnStartAndStop
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let base = ClickerConfig()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        mode = value(.mode, base.mode)
        intervalMilliseconds = value(.intervalMilliseconds, base.intervalMilliseconds)
        entersRateAsCPS = value(.entersRateAsCPS, base.entersRateAsCPS)
        jitterPercent = value(.jitterPercent, base.jitterPercent)
        button = value(.button, base.button)
        isDoubleClick = value(.isDoubleClick, base.isDoubleClick)
        clickModifiers = value(.clickModifiers, base.clickModifiers)
        burstCount = value(.burstCount, base.burstCount)
        burstGapMilliseconds = value(.burstGapMilliseconds, base.burstGapMilliseconds)
        usesCycles = value(.usesCycles, base.usesCycles)
        cycleOnSeconds = value(.cycleOnSeconds, base.cycleOnSeconds)
        cycleOffSeconds = value(.cycleOffSeconds, base.cycleOffSeconds)
        target = value(.target, base.target)
        point = value(.point, base.point)
        regionStart = value(.regionStart, base.regionStart)
        regionEnd = value(.regionEnd, base.regionEnd)
        limit = value(.limit, base.limit)
        clickCount = value(.clickCount, base.clickCount)
        durationSeconds = value(.durationSeconds, base.durationSeconds)
        startDelaySeconds = value(.startDelaySeconds, base.startDelaySeconds)
        holdMilliseconds = value(.holdMilliseconds, base.holdMilliseconds)
        keyCode = value(.keyCode, base.keyCode)
        keyModifiers = value(.keyModifiers, base.keyModifiers)
        restoresCursor = value(.restoresCursor, base.restoresCursor)
        stopsIfPointerMoves = value(.stopsIfPointerMoves, base.stopsIfPointerMoves)
        pointerMoveTolerance = value(.pointerMoveTolerance, base.pointerMoveTolerance)
        beepsOnStartAndStop = value(.beepsOnStartAndStop, base.beepsOnStartAndStop)
    }
}

// MARK: - The engine

/// Fires clicks or keystrokes on a timer until told to stop. Same shape as
/// MacroPlayer: a background thread, a lock-guarded cancel flag, and every
/// published change hopped back to the main queue.
final class AutoClicker: ObservableObject {

    enum Phase: String {
        case idle
        case waiting     // start delay
        case clicking
        case resting     // between work cycles

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .waiting: return "Starting"
            case .clicking: return "Clicking"
            case .resting: return "Resting"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var clicksSent = 0
    @Published private(set) var countdownRemaining = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// Seconds left on whatever is counting down — the run timer, or the
    /// current work/rest phase.
    @Published private(set) var phaseRemaining: Int = 0
    /// Why it ended, when it wasn't you.
    @Published private(set) var stoppedBecause: String?
    /// Set when it refused to start, so the UI can say why.
    @Published private(set) var problem: String?

    private var token: Token?
    private var generation = 0

    var isCountingDown: Bool { countdownRemaining > 0 }

    // MARK: Control

    func toggle(config: ClickerConfig) {
        if isRunning {
            stop()
        } else {
            start(config: config)
        }
    }

    func start(config: ClickerConfig) {
        guard !isRunning else { return }
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.requestPrompt()
            problem = "Accessibility access is needed before anything can be clicked."
            return
        }
        if config.target == .region && !config.hasRegion {
            problem = "Set both corners of the box first."
            return
        }

        problem = nil
        stoppedBecause = nil
        let token = Token()
        self.token = token
        generation += 1
        let run = generation

        isRunning = true
        phase = config.startDelaySeconds > 0 ? .waiting : .clicking
        clicksSent = 0
        elapsed = 0
        phaseRemaining = 0
        countdownRemaining = config.startDelaySeconds

        if config.beepsOnStartAndStop { NSSound.beep() }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var remaining = config.startDelaySeconds
            while remaining > 0 && !token.isCancelled {
                let tick = remaining
                DispatchQueue.main.async { self?.report(countdown: tick, run: run) }
                Thread.sleep(forTimeInterval: 1)
                remaining -= 1
            }
            DispatchQueue.main.async { self?.report(countdown: 0, run: run) }

            let savedCursor = CGEvent(source: nil)?.location
            let started = Date()
            var sent = 0
            var reason: String?

            var isResting = false
            var phaseStarted = Date()

            while !token.isCancelled {
                // Limits first, so a finished run never fires one extra.
                switch config.limit {
                case .forever:
                    break
                case .count:
                    if sent >= max(1, config.clickCount) {
                        reason = "Sent all \(config.clickCount)."
                        token.cancel()
                    }
                case .duration:
                    if Date().timeIntervalSince(started) >= Double(max(1, config.durationSeconds)) {
                        reason = "Time was up."
                        token.cancel()
                    }
                }
                if token.isCancelled { break }

                // Work / rest cycles.
                if config.usesCycles {
                    let inPhase = Date().timeIntervalSince(phaseStarted)
                    let limitForPhase = Double(max(1, isResting ? config.cycleOffSeconds : config.cycleOnSeconds))

                    if inPhase >= limitForPhase {
                        isResting.toggle()
                        phaseStarted = Date()
                        continue
                    }

                    if isResting {
                        let left = Int((limitForPhase - inPhase).rounded(.up))
                        DispatchQueue.main.async {
                            self?.report(phase: .resting, phaseRemaining: left, run: run)
                        }
                        Self.interruptibleSleep(0.1, token: token)
                        continue
                    }

                    let left = Int((limitForPhase - inPhase).rounded(.up))
                    DispatchQueue.main.async {
                        self?.report(phase: .clicking, phaseRemaining: left, run: run)
                    }
                }

                // A burst is several presses back to back; the default of
                // one just fires once.
                let burst = max(1, config.burstCount)
                for index in 0..<burst {
                    if token.isCancelled { break }
                    Self.fire(config: config)
                    sent += 1
                    if index < burst - 1 {
                        Self.interruptibleSleep(Double(max(0, config.burstGapMilliseconds)) / 1000, token: token)
                    }
                }

                let count = sent
                let since = Date().timeIntervalSince(started)
                let runLeft = config.limit == .duration
                    ? max(0, Int(Double(config.durationSeconds) - since))
                    : 0
                DispatchQueue.main.async {
                    self?.report(sent: count, elapsed: since, run: run)
                    if config.limit == .duration && !config.usesCycles {
                        self?.report(phase: .clicking, phaseRemaining: runLeft, run: run)
                    }
                }

                var gap = Double(config.effectiveInterval) / 1000
                if config.jitterPercent > 0 {
                    let spread = gap * (config.jitterPercent / 100)
                    gap = max(0.001, gap + Double.random(in: -spread...spread))
                }

                // Nothing here moves the pointer, so anything that changes
                // its position across the gap was a hand on the mouse.
                let before = config.stopsIfPointerMoves ? CGEvent(source: nil)?.location : nil
                Self.interruptibleSleep(gap, token: token)

                if config.stopsIfPointerMoves,
                   let before,
                   let after = CGEvent(source: nil)?.location {
                    let moved = hypot(after.x - before.x, after.y - before.y)
                    if moved > max(1, config.pointerMoveTolerance) {
                        reason = "You moved the pointer."
                        token.cancel()
                    }
                }
            }

            if config.restoresCursor, config.target != .cursor, let savedCursor {
                Self.move(to: savedCursor)
            }
            if config.beepsOnStartAndStop {
                DispatchQueue.main.async { NSSound.beep() }
            }

            let ending = reason
            DispatchQueue.main.async { self?.finish(run: run, reason: ending) }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
        generation += 1
        clear()
    }

    func clearProblem() {
        problem = nil
        stoppedBecause = nil
    }

    // MARK: State, main thread only

    private func report(countdown: Int, run: Int) {
        guard run == generation else { return }
        countdownRemaining = countdown
        phase = countdown > 0 ? .waiting : .clicking
    }

    private func report(sent: Int, elapsed seconds: TimeInterval, run: Int) {
        guard run == generation else { return }
        clicksSent = sent
        elapsed = seconds
    }

    private func report(phase newPhase: Phase, phaseRemaining left: Int, run: Int) {
        guard run == generation else { return }
        phase = newPhase
        phaseRemaining = left
    }

    private func finish(run: Int, reason: String?) {
        guard run == generation else { return }
        token = nil
        stoppedBecause = reason
        clear()
    }

    private func clear() {
        isRunning = false
        phase = .idle
        countdownRemaining = 0
        phaseRemaining = 0
    }

    // MARK: Posting

    private static func fire(config: ClickerConfig) {
        switch config.mode {
        case .click:
            let location = resolveLocation(config)
            if config.target != .cursor { move(to: location) }
            click(config: config, at: location, clickState: 1)
            if config.isDoubleClick {
                Thread.sleep(forTimeInterval: 0.04)
                click(config: config, at: location, clickState: 2)
            }
        case .keystroke:
            key(config: config)
        }
    }

    private static func resolveLocation(_ config: ClickerConfig) -> CGPoint {
        switch config.target {
        case .cursor:
            return CGEvent(source: nil)?.location ?? .zero
        case .point:
            return config.point.cgPoint
        case .region:
            let rect = config.regionRect
            guard rect.width > 1, rect.height > 1 else { return config.regionStart.cgPoint }
            return CGPoint(
                x: Double.random(in: rect.minX...rect.maxX),
                y: Double.random(in: rect.minY...rect.maxY)
            )
        }
    }

    private static func move(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    private static func click(config: ClickerConfig, at point: CGPoint, clickState: Int64) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = config.clickModifiers.cgEventFlags

        let down: CGEventType
        let up: CGEventType
        let button: CGMouseButton
        switch config.button {
        case .left:
            down = .leftMouseDown; up = .leftMouseUp; button = .left
        case .right:
            down = .rightMouseDown; up = .rightMouseUp; button = .right
        case .middle:
            down = .otherMouseDown; up = .otherMouseUp; button = .center
        }

        let downEvent = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: point, mouseButton: button)
        downEvent?.flags = flags
        downEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
        downEvent?.post(tap: .cghidEventTap)

        if config.holdMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(config.holdMilliseconds) / 1000)
        }

        let upEvent = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: point, mouseButton: button)
        upEvent?.flags = flags
        upEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
        upEvent?.post(tap: .cghidEventTap)
    }

    private static func key(config: ClickerConfig) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = config.keyModifiers.cgEventFlags

        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(config.keyCode), keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        if config.holdMilliseconds > 0 {
            Thread.sleep(forTimeInterval: Double(config.holdMilliseconds) / 1000)
        }

        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(config.keyCode), keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    /// A 5-second rest shouldn't make Stop feel broken.
    private static func interruptibleSleep(_ duration: TimeInterval, token: Token) {
        guard duration > 0 else { return }
        let slice: TimeInterval = 0.02
        var remaining = duration
        while remaining > 0 && !token.isCancelled {
            let step = min(slice, remaining)
            Thread.sleep(forTimeInterval: step)
            remaining -= step
        }
    }

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

// MARK: - Picking a point on screen

/// Counts down, then grabs wherever the pointer is. A countdown rather than
/// "click to pick" on purpose: a click would go through to whatever is
/// underneath, which is usually a game.
final class ScreenPointPicker: ObservableObject {
    @Published private(set) var countdown = 0
    @Published private(set) var picked: CGPoint?
    /// Which field asked for the point, so one picker can serve several.
    @Published private(set) var slot: String?

    private var timer: Timer?

    var isPicking: Bool { countdown > 0 }

    deinit {
        timer?.invalidate()
    }

    func pick(slot: String, seconds: Int = 3, completion: @escaping (CGPoint) -> Void) {
        guard !isPicking else { return }
        self.slot = slot
        countdown = max(1, seconds)
        picked = nil

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return }
            countdown -= 1
            if countdown <= 0 {
                timer.invalidate()
                self.timer = nil
                self.slot = nil
                let point = CGEvent(source: nil)?.location ?? .zero
                picked = point
                completion(point)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        countdown = 0
        slot = nil
    }
}
