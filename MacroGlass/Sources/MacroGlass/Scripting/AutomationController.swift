import Foundation
import Combine
import AppKit

extension Notification.Name {
    static let macroPlaybackFinished = Notification.Name("MacroGlass.macroPlaybackFinished")
}

/// Drives auto-execution: runs a chosen saved script when the app opens,
/// on a timer, or right after a macro finishes playing.
///
/// Created empty so it can be a `@StateObject`, then `attach(settings:store:)`
/// hands it its dependencies once the view exists.
final class AutomationController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastRunReason: String?
    @Published private(set) var lastRunDate: Date?
    @Published private(set) var lastRunExitCode: Int32?

    private var settings: AppSettings?
    private var store: MacroStore?
    private var registry: LanguageRegistry?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var didRunOnLaunch = false

    deinit {
        timer?.invalidate()
    }

    func attach(settings: AppSettings, store: MacroStore, registry: LanguageRegistry) {
        guard self.settings == nil else { return }
        self.settings = settings
        self.store = store
        self.registry = registry

        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reschedule() }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .macroPlaybackFinished)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.settings?.autoRunTrigger == .afterPlayback else { return }
                self.run(reason: "after playback")
            }
            .store(in: &bag)

        reschedule()
    }

    var selectedScript: SavedScript? {
        guard let settings, let store else { return nil }
        return store.scripts.first { $0.id.uuidString == settings.autoRunScriptID }
    }

    var statusLine: String {
        guard let settings, settings.autoRunTrigger != .off else {
            return "Nothing runs on its own."
        }
        guard let script = selectedScript else {
            return "Pick a saved script to run automatically."
        }
        switch settings.autoRunTrigger {
        case .off:
            return "Nothing runs on its own."
        case .launch:
            return "“\(script.name)” runs when MacroGlass opens."
        case .interval:
            return "“\(script.name)” runs every \(settings.autoRunIntervalMinutes) min while the app is open."
        case .afterPlayback:
            return "“\(script.name)” runs after each macro finishes playing."
        }
    }

    /// Called once, when the window first appears.
    func handleLaunch() {
        guard !didRunOnLaunch else { return }
        didRunOnLaunch = true
        if settings?.autoRunTrigger == .launch {
            run(reason: "on launch")
        }
    }

    func run(reason: String) {
        guard !isRunning, let script = selectedScript else { return }
        isRunning = true
        lastRunReason = reason

        let options = settings?.runOptions ?? ScriptRunner.RunOptions()
        let choice = registry?.choice(for: script) ?? LanguageChoice(script.language)
        let libraries = registry?.libraries ?? []

        Task { [weak self] in
            let result = await ScriptRunner.run(
                choice: choice,
                content: script.content,
                libraries: libraries,
                options: options
            )
            // Hopping back through an isolated method keeps the weak
            // reference out of the concurrent closure, which Swift 6 mode
            // rejects.
            await self?.finish(script: script, result: result)
        }
    }

    @MainActor
    private func finish(script: SavedScript, result: ScriptRunner.RunResult) {
        isRunning = false
        lastRunDate = Date()
        lastRunExitCode = result.exitCode
        if settings?.autoRunNotifies == true && result.exitCode != 0 {
            reportFailure(script: script, result: result)
        }
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil

        guard let settings, settings.autoRunTrigger == .interval, selectedScript != nil else { return }

        let seconds = Double(max(1, settings.autoRunIntervalMinutes)) * 60
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            self?.run(reason: "timer")
        }
        timer.tolerance = seconds * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func reportFailure(script: SavedScript, result: ScriptRunner.RunResult) {
        let alert = NSAlert()
        alert.messageText = "“\(script.name)” exited with code \(result.exitCode)"
        let detail = result.error.isEmpty ? result.output : result.error
        alert.informativeText = String(detail.prefix(400))
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
