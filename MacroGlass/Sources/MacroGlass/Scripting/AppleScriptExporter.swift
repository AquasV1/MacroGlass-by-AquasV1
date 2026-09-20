import Foundation

/// Best-effort export of a recorded Macro into an editable AppleScript,
/// so a Record-tab capture can be dropped straight into the Script tab.
enum AppleScriptExporter {
    static func generate(for macro: Macro) -> String {
        var lines = [
            "-- Generated from macro: \(macro.name)",
            "-- Mouse clicks are exported as comments: System Events has no",
            "-- built-in \"click at point\" command. A tool like cliclick can",
            "-- fill those in if you need precise click automation.",
            "tell application \"System Events\""
        ]

        for event in macro.events {
            switch event.type {
            case .keyDown:
                if let code = event.keyCode {
                    lines.append("    key code \(code)")
                }
            case .leftMouseDown:
                if let p = event.point {
                    lines.append("    -- click at \(Int(p.x)), \(Int(p.y))")
                }
            case .rightMouseDown:
                if let p = event.point {
                    lines.append("    -- right click at \(Int(p.x)), \(Int(p.y))")
                }
            default:
                break
            }
        }

        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
}
