import SwiftUI
import AppKit

@main
struct MacroGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("MacroGlass") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 560)
        .commands {
            // Nothing here opens a document, so drop File ▸ New. Everything
            // else — the Edit menu that gives ⌘C/⌘V/⌘Z their key
            // equivalents inside the editor — is SwiftUI's default set.
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - Activation
//
// THE reason nothing could be typed into this app.
//
// A SwiftPM `executableTarget` builds a bare Mach-O — no `.app` wrapper and
// no Info.plist — so LaunchServices files the process under "command line
// tool" and NSApplication comes up with an activation policy that is not
// `.regular`. An app that isn't `.regular` is never permitted to own the
// key window: its windows still draw, and still take mouse clicks, which is
// why every button worked. But keystrokes go to the key window of the
// *active* application, which was Xcode or Terminal — so the code editor,
// the script-name field and the macro-name sheet all sat there ignoring the
// keyboard.
//
// Declaring `.regular` at launch and activating is the whole fix. It also
// gets the app a Dock icon and a menu bar, which it should have had anyway.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        claimKeyWindow(attemptsLeft: 20)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        claimKeyWindow(attemptsLeft: 1)
    }

    /// SwiftUI builds its window a few runloop turns after launch, so the
    /// first look at `NSApp.windows` is usually empty — poll briefly rather
    /// than giving up on it.
    private func claimKeyWindow(attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }

        if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
            if window.isKeyWindow { return }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.claimKeyWindow(attemptsLeft: attemptsLeft - 1)
        }
    }
}
