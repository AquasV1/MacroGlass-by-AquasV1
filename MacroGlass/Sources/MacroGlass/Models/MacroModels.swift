import Foundation
import CoreGraphics

/// Codable stand-in for CGPoint (CGPoint itself isn't Codable).
struct CGPointCodable: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

/// One captured input event (a key press, a click, a scroll) with a
/// timestamp measured in seconds from the start of the recording.
struct MacroEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case keyDown, keyUp, leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp, mouseMoved, scrollWheel
    }

    struct Modifiers: Codable, Hashable {
        var command = false
        var option = false
        var control = false
        var shift = false

        init() {}

        init(flags: CGEventFlags) {
            command = flags.contains(.maskCommand)
            option = flags.contains(.maskAlternate)
            control = flags.contains(.maskControl)
            shift = flags.contains(.maskShift)
        }

        var cgEventFlags: CGEventFlags {
            var flags: CGEventFlags = []
            if command { flags.insert(.maskCommand) }
            if option { flags.insert(.maskAlternate) }
            if control { flags.insert(.maskControl) }
            if shift { flags.insert(.maskShift) }
            return flags
        }
    }

    var id = UUID()
    var type: Kind
    var timestamp: TimeInterval
    var keyCode: UInt16?
    var modifiers: Modifiers?
    var point: CGPointCodable?
    var scrollDeltaY: Double?

    var summary: String {
        switch type {
        case .keyDown, .keyUp:
            let name = keyCode.map { KeyCodes.name(for: $0) } ?? "?"
            var prefix = ""
            if let modifiers {
                if modifiers.control { prefix += "⌃" }
                if modifiers.option { prefix += "⌥" }
                if modifiers.shift { prefix += "⇧" }
                if modifiers.command { prefix += "⌘" }
            }
            return "\(type == .keyDown ? "Press" : "Release") \(prefix)\(name)"
        case .leftMouseDown:
            return "Left click\(pointSuffix)"
        case .leftMouseUp:
            return "Left release\(pointSuffix)"
        case .rightMouseDown:
            return "Right click\(pointSuffix)"
        case .rightMouseUp:
            return "Right release\(pointSuffix)"
        case .mouseMoved:
            return "Move\(pointSuffix)"
        case .scrollWheel:
            let delta = scrollDeltaY ?? 0
            return "Scroll \(delta > 0 ? "up" : "down") \(abs(Int(delta)))"
        }
    }

    private var pointSuffix: String {
        guard let point else { return "" }
        return String(format: " at %.0f, %.0f", point.x, point.y)
    }

    var symbol: String {
        switch type {
        case .keyDown, .keyUp: return "keyboard"
        case .leftMouseDown, .leftMouseUp: return "cursorarrow.click"
        case .rightMouseDown, .rightMouseUp: return "cursorarrow.click.2"
        case .mouseMoved: return "arrow.up.and.down.and.arrow.left.and.right"
        case .scrollWheel: return "scroll"
        }
    }
}

/// A global key combination that fires a macro from anywhere.
struct MacroHotkey: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: MacroEvent.Modifiers

    init(keyCode: UInt16, modifiers: MacroEvent.Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayName: String {
        var prefix = ""
        if modifiers.control { prefix += "⌃" }
        if modifiers.option { prefix += "⌥" }
        if modifiers.shift { prefix += "⇧" }
        if modifiers.command { prefix += "⌘" }
        return prefix + KeyCodes.name(for: keyCode)
    }

    func matches(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard keyCode == self.keyCode else { return false }
        return MacroEvent.Modifiers(flags: flags) == modifiers
    }
}

/// A named, saved recording.
///
/// `hotkey` and `notes` are Optional on purpose: Swift's synthesized
/// decoder ignores default values and throws on a missing key, so anything
/// added after the first release has to be Optional or the macros.json
/// already on disk stops loading.
struct Macro: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var events: [MacroEvent]
    var hotkey: MacroHotkey? = nil
    var notes: String? = nil

    var duration: TimeInterval { events.last?.timestamp ?? 0 }

    var keystrokeCount: Int {
        events.filter { $0.type == .keyDown }.count
    }

    var clickCount: Int {
        events.filter { $0.type == .leftMouseDown || $0.type == .rightMouseDown }.count
    }

    var moveCount: Int {
        events.filter { $0.type == .mouseMoved }.count
    }

    var scrollCount: Int {
        events.filter { $0.type == .scrollWheel }.count
    }

    /// "12 keys · 4 clicks · 30 moves", skipping whatever is zero.
    var breakdown: String {
        var parts: [String] = []
        if keystrokeCount > 0 { parts.append("\(keystrokeCount) keys") }
        if clickCount > 0 { parts.append("\(clickCount) clicks") }
        if scrollCount > 0 { parts.append("\(scrollCount) scrolls") }
        if moveCount > 0 { parts.append("\(moveCount) moves") }
        return parts.isEmpty ? "empty" : parts.joined(separator: " · ")
    }

    /// Drops dead air at the start and end, and optionally squeezes any gap
    /// longer than `maxGap` down to it, so a macro recorded with pauses for
    /// thinking replays at a usable pace.
    func trimmed(maxGap: TimeInterval = 0) -> Macro {
        guard let first = events.first else { return self }

        var rebuilt: [MacroEvent] = []
        var previousOriginal = first.timestamp
        var cursor: TimeInterval = 0

        for event in events {
            var gap = event.timestamp - previousOriginal
            if maxGap > 0 { gap = min(gap, maxGap) }
            cursor += max(0, gap)
            previousOriginal = event.timestamp

            var copy = event
            copy.timestamp = cursor
            rebuilt.append(copy)
        }

        var result = self
        result.events = rebuilt
        return result
    }
}

/// A named, saved script.
///
/// `customLanguageID` points at a language the user added themselves; when
/// it's nil the built-in `language` case is used. Optional for the same
/// backward-compatibility reason as Macro's new fields.
struct SavedScript: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var language: ScriptLanguage
    var content: String
    var updatedAt = Date()
    var customLanguageID: String? = nil
}
