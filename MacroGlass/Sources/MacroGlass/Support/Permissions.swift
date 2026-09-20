import ApplicationServices
import AppKit

/// Wraps the Accessibility (AXIsProcessTrusted) checks that recording and
/// playback both need.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system "MacroGlass would like to control this
    /// computer" prompt if permission hasn't been decided yet.
    static func requestPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
