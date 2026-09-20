import Foundation
import Combine
import SwiftUI
import AppKit

enum AutoRunTrigger: String, CaseIterable, Identifiable {
    case off
    case launch
    case interval
    case afterPlayback

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .launch: return "When the app opens"
        case .interval: return "On a timer"
        case .afterPlayback: return "After a macro plays"
        }
    }
}

/// Every user-facing preference in one observable object, persisted to
/// UserDefaults. A single debounced sink writes the whole set whenever
/// anything changes, so adding a setting means adding a property, a
/// default and one line in `persist()`.
final class AppSettings: ObservableObject {

    // Appearance
    @Published var glassTintHex: String
    @Published var glassIntensity: Double
    @Published var floatOnTop: Bool

    // General
    @Published var launchAtLogin: Bool
    /// Which half of the app opens on launch, or ask.
    @Published var startupMode: StartupMode

    // Playback
    @Published var playbackSpeed: Double
    @Published var repeatCount: Int
    @Published var countdownSeconds: Int
    @Published var loopsForever: Bool
    @Published var playbackJitterPercent: Double
    @Published var restoresCursorAfterPlayback: Bool
    @Published var pauseBetweenLoops: Double

    // Recording
    @Published var recordsMouseMovement: Bool
    @Published var stopsWithEscape: Bool
    @Published var recordCountdownSeconds: Int
    @Published var maxRecordingSeconds: Int
    @Published var ignoresModifierOnlyKeys: Bool

    // Auto clicker
    @Published var clicker: ClickerConfig

    // Hotkeys
    @Published var panicHotkey: MacroHotkey?
    @Published var recordHotkey: MacroHotkey?
    @Published var clickerHotkey: MacroHotkey?

    // Editor
    @Published var editorFontName: String
    @Published var editorFontSize: Double
    @Published var showsLineNumbers: Bool
    @Published var highlightsCurrentLine: Bool
    @Published var tabWidth: Int
    @Published var insertsSpacesForTab: Bool
    @Published var wrapsLines: Bool
    @Published var autoIndents: Bool
    @Published var autoClosesBrackets: Bool

    // Script execution
    @Published var scriptTimeoutSeconds: Int
    @Published var scriptWorkingDirectory: String
    @Published var scriptExtraPATH: String
    /// Paths, most recent first. Shown in the Library menu.
    @Published var recentFiles: [String]

    // Automation
    @Published var autoRunTrigger: AutoRunTrigger
    @Published var autoRunScriptID: String
    @Published var autoRunIntervalMinutes: Int
    @Published var autoRunNotifies: Bool

    // AutoHotkey
    @Published var ahkMapsControlToCommand: Bool
    @Published var ahkExecutablePath: String

    private var bag = Set<AnyCancellable>()

    static let systemFontToken = "__system__"

    private enum K {
        static let glassTintHex = "glassTintHex"
        static let glassIntensity = "glassIntensity"
        static let floatOnTop = "floatOnTop"
        static let launchAtLogin = "launchAtLogin"
        static let startupMode = "startupMode"
        static let playbackSpeed = "playbackSpeed"
        static let repeatCount = "repeatCount"
        static let countdownSeconds = "countdownSeconds"
        static let loopsForever = "loopsForever"
        static let playbackJitterPercent = "playbackJitterPercent"
        static let restoresCursorAfterPlayback = "restoresCursorAfterPlayback"
        static let pauseBetweenLoops = "pauseBetweenLoops"
        static let recordsMouseMovement = "recordsMouseMovement"
        static let stopsWithEscape = "stopsWithEscape"
        static let recordCountdownSeconds = "recordCountdownSeconds"
        static let maxRecordingSeconds = "maxRecordingSeconds"
        static let ignoresModifierOnlyKeys = "ignoresModifierOnlyKeys"
        static let clicker = "clickerConfig"
        static let panicHotkey = "panicHotkey"
        static let recordHotkey = "recordHotkey"
        static let clickerHotkey = "clickerHotkey"
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
        static let showsLineNumbers = "showsLineNumbers"
        static let highlightsCurrentLine = "highlightsCurrentLine"
        static let tabWidth = "tabWidth"
        static let insertsSpacesForTab = "insertsSpacesForTab"
        static let wrapsLines = "wrapsLines"
        static let autoIndents = "autoIndents"
        static let autoClosesBrackets = "autoClosesBrackets"
        static let scriptTimeoutSeconds = "scriptTimeoutSeconds"
        static let scriptWorkingDirectory = "scriptWorkingDirectory"
        static let scriptExtraPATH = "scriptExtraPATH"
        static let recentFiles = "recentFiles"
        static let autoRunTrigger = "autoRunTrigger"
        static let autoRunScriptID = "autoRunScriptID"
        static let autoRunIntervalMinutes = "autoRunIntervalMinutes"
        static let autoRunNotifies = "autoRunNotifies"
        static let ahkMapsControlToCommand = "ahkMapsControlToCommand"
        static let ahkExecutablePath = "ahkExecutablePath"
    }

    init() {
        let d = UserDefaults.standard

        glassTintHex = d.string(forKey: K.glassTintHex) ?? "4C8DFF"
        glassIntensity = d.object(forKey: K.glassIntensity) as? Double ?? 1.0
        floatOnTop = d.object(forKey: K.floatOnTop) as? Bool ?? false

        launchAtLogin = d.object(forKey: K.launchAtLogin) as? Bool ?? false
        startupMode = StartupMode(rawValue: d.string(forKey: K.startupMode) ?? "") ?? .ask

        playbackSpeed = d.object(forKey: K.playbackSpeed) as? Double ?? 1.0
        repeatCount = d.object(forKey: K.repeatCount) as? Int ?? 1
        countdownSeconds = d.object(forKey: K.countdownSeconds) as? Int ?? 0
        loopsForever = d.object(forKey: K.loopsForever) as? Bool ?? false
        playbackJitterPercent = d.object(forKey: K.playbackJitterPercent) as? Double ?? 0
        restoresCursorAfterPlayback = d.object(forKey: K.restoresCursorAfterPlayback) as? Bool ?? true
        pauseBetweenLoops = d.object(forKey: K.pauseBetweenLoops) as? Double ?? 0

        recordsMouseMovement = d.object(forKey: K.recordsMouseMovement) as? Bool ?? false
        stopsWithEscape = d.object(forKey: K.stopsWithEscape) as? Bool ?? true
        recordCountdownSeconds = d.object(forKey: K.recordCountdownSeconds) as? Int ?? 0
        maxRecordingSeconds = d.object(forKey: K.maxRecordingSeconds) as? Int ?? 0
        ignoresModifierOnlyKeys = d.object(forKey: K.ignoresModifierOnlyKeys) as? Bool ?? true

        if let data = d.data(forKey: K.clicker),
           let decoded = try? JSONDecoder().decode(ClickerConfig.self, from: data) {
            clicker = decoded
        } else {
            clicker = ClickerConfig()
        }

        panicHotkey = AppSettings.decodeHotkey(d.data(forKey: K.panicHotkey))
        recordHotkey = AppSettings.decodeHotkey(d.data(forKey: K.recordHotkey))
        clickerHotkey = AppSettings.decodeHotkey(d.data(forKey: K.clickerHotkey))

        editorFontName = d.string(forKey: K.editorFontName) ?? AppSettings.systemFontToken
        editorFontSize = d.object(forKey: K.editorFontSize) as? Double ?? 12.5
        showsLineNumbers = d.object(forKey: K.showsLineNumbers) as? Bool ?? true
        highlightsCurrentLine = d.object(forKey: K.highlightsCurrentLine) as? Bool ?? true
        tabWidth = d.object(forKey: K.tabWidth) as? Int ?? 4
        insertsSpacesForTab = d.object(forKey: K.insertsSpacesForTab) as? Bool ?? true
        wrapsLines = d.object(forKey: K.wrapsLines) as? Bool ?? true
        autoIndents = d.object(forKey: K.autoIndents) as? Bool ?? true
        autoClosesBrackets = d.object(forKey: K.autoClosesBrackets) as? Bool ?? true

        scriptTimeoutSeconds = d.object(forKey: K.scriptTimeoutSeconds) as? Int ?? 0
        scriptWorkingDirectory = d.string(forKey: K.scriptWorkingDirectory) ?? ""
        scriptExtraPATH = d.string(forKey: K.scriptExtraPATH) ?? ""
        recentFiles = d.stringArray(forKey: K.recentFiles) ?? []

        autoRunTrigger = AutoRunTrigger(rawValue: d.string(forKey: K.autoRunTrigger) ?? "") ?? .off
        autoRunScriptID = d.string(forKey: K.autoRunScriptID) ?? ""
        autoRunIntervalMinutes = d.object(forKey: K.autoRunIntervalMinutes) as? Int ?? 15
        autoRunNotifies = d.object(forKey: K.autoRunNotifies) as? Bool ?? true

        ahkMapsControlToCommand = d.object(forKey: K.ahkMapsControlToCommand) as? Bool ?? true
        ahkExecutablePath = d.string(forKey: K.ahkExecutablePath) ?? ""

        // objectWillChange fires just before a property changes; the short
        // debounce means persist() reads the settled values.
        objectWillChange
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &bag)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(glassTintHex, forKey: K.glassTintHex)
        d.set(glassIntensity, forKey: K.glassIntensity)
        d.set(floatOnTop, forKey: K.floatOnTop)
        d.set(launchAtLogin, forKey: K.launchAtLogin)
        d.set(startupMode.rawValue, forKey: K.startupMode)
        d.set(playbackSpeed, forKey: K.playbackSpeed)
        d.set(repeatCount, forKey: K.repeatCount)
        d.set(countdownSeconds, forKey: K.countdownSeconds)
        d.set(loopsForever, forKey: K.loopsForever)
        d.set(playbackJitterPercent, forKey: K.playbackJitterPercent)
        d.set(restoresCursorAfterPlayback, forKey: K.restoresCursorAfterPlayback)
        d.set(pauseBetweenLoops, forKey: K.pauseBetweenLoops)
        d.set(recordsMouseMovement, forKey: K.recordsMouseMovement)
        d.set(stopsWithEscape, forKey: K.stopsWithEscape)
        d.set(recordCountdownSeconds, forKey: K.recordCountdownSeconds)
        d.set(maxRecordingSeconds, forKey: K.maxRecordingSeconds)
        d.set(ignoresModifierOnlyKeys, forKey: K.ignoresModifierOnlyKeys)
        d.set(try? JSONEncoder().encode(clicker), forKey: K.clicker)
        d.set(AppSettings.encodeHotkey(panicHotkey), forKey: K.panicHotkey)
        d.set(AppSettings.encodeHotkey(recordHotkey), forKey: K.recordHotkey)
        d.set(AppSettings.encodeHotkey(clickerHotkey), forKey: K.clickerHotkey)
        d.set(editorFontName, forKey: K.editorFontName)
        d.set(editorFontSize, forKey: K.editorFontSize)
        d.set(showsLineNumbers, forKey: K.showsLineNumbers)
        d.set(highlightsCurrentLine, forKey: K.highlightsCurrentLine)
        d.set(tabWidth, forKey: K.tabWidth)
        d.set(insertsSpacesForTab, forKey: K.insertsSpacesForTab)
        d.set(wrapsLines, forKey: K.wrapsLines)
        d.set(autoIndents, forKey: K.autoIndents)
        d.set(autoClosesBrackets, forKey: K.autoClosesBrackets)
        d.set(scriptTimeoutSeconds, forKey: K.scriptTimeoutSeconds)
        d.set(scriptWorkingDirectory, forKey: K.scriptWorkingDirectory)
        d.set(scriptExtraPATH, forKey: K.scriptExtraPATH)
        d.set(recentFiles, forKey: K.recentFiles)
        d.set(autoRunTrigger.rawValue, forKey: K.autoRunTrigger)
        d.set(autoRunScriptID, forKey: K.autoRunScriptID)
        d.set(autoRunIntervalMinutes, forKey: K.autoRunIntervalMinutes)
        d.set(autoRunNotifies, forKey: K.autoRunNotifies)
        d.set(ahkMapsControlToCommand, forKey: K.ahkMapsControlToCommand)
        d.set(ahkExecutablePath, forKey: K.ahkExecutablePath)
    }

    /// Newest first, no duplicates, capped — and paths that have since been
    /// deleted are dropped rather than sitting in the menu doing nothing.
    func noteRecentFile(_ path: String) {
        var updated = recentFiles.filter { $0 != path }
        updated.insert(path, at: 0)
        recentFiles = Array(updated.prefix(10)).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func encodeHotkey(_ hotkey: MacroHotkey?) -> Data? {
        guard let hotkey else { return nil }
        return try? JSONEncoder().encode(hotkey)
    }

    private static func decodeHotkey(_ data: Data?) -> MacroHotkey? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(MacroHotkey.self, from: data)
    }

    // MARK: Bundled option sets

    /// Passed to ScriptRunner so the AutoHotkey engine and the process
    /// launcher both know how to behave.
    var runOptions: ScriptRunner.RunOptions {
        ScriptRunner.RunOptions(
            ahkMapsControlToCommand: ahkMapsControlToCommand,
            ahkExecutablePath: ahkExecutablePath,
            timeoutSeconds: max(0, scriptTimeoutSeconds),
            workingDirectory: scriptWorkingDirectory,
            extraPATH: scriptExtraPATH
        )
    }

    var playbackOptions: MacroPlayer.Options {
        MacroPlayer.Options(
            speed: playbackSpeed,
            repeatCount: repeatCount,
            loopsForever: loopsForever,
            countdown: countdownSeconds,
            jitterPercent: playbackJitterPercent,
            restoresCursor: restoresCursorAfterPlayback,
            pauseBetweenLoops: pauseBetweenLoops
        )
    }

    func resetToDefaults() {
        glassTintHex = "4C8DFF"
        glassIntensity = 1.0
        floatOnTop = false
        startupMode = .ask
        playbackSpeed = 1.0
        repeatCount = 1
        countdownSeconds = 0
        loopsForever = false
        playbackJitterPercent = 0
        restoresCursorAfterPlayback = true
        pauseBetweenLoops = 0
        recordsMouseMovement = false
        stopsWithEscape = true
        recordCountdownSeconds = 0
        maxRecordingSeconds = 0
        ignoresModifierOnlyKeys = true
        clicker = ClickerConfig()
        panicHotkey = nil
        recordHotkey = nil
        clickerHotkey = nil
        editorFontName = AppSettings.systemFontToken
        editorFontSize = 12.5
        showsLineNumbers = true
        highlightsCurrentLine = true
        tabWidth = 4
        insertsSpacesForTab = true
        wrapsLines = true
        autoIndents = true
        autoClosesBrackets = true
        scriptTimeoutSeconds = 0
        scriptWorkingDirectory = ""
        scriptExtraPATH = ""
        recentFiles = []
        autoRunTrigger = .off
        autoRunScriptID = ""
        autoRunIntervalMinutes = 15
        autoRunNotifies = true
        ahkMapsControlToCommand = true
        ahkExecutablePath = ""
    }

    // MARK: Fonts

    var tint: Color { Color(hex: glassTintHex) }

    var usesSystemEditorFont: Bool { editorFontName == AppSettings.systemFontToken }

    var editorFontDisplayName: String {
        usesSystemEditorFont ? "System Mono" : editorFontName
    }

    func editorFont(delta: Double = 0) -> Font {
        let size = editorFontSize + delta
        return usesSystemEditorFont
            ? .system(size: size, design: .monospaced)
            : .custom(editorFontName, size: size)
    }

    func editorNSFont(delta: Double = 0) -> NSFont {
        let size = editorFontSize + delta
        if usesSystemEditorFont {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        // Family names work for most fonts; for the ones that need a
        // PostScript name (JetBrains Mono, Fira Code…) fall back to the
        // family's first installed face before giving up.
        if let font = NSFont(name: editorFontName, size: size) {
            return font
        }
        if let member = NSFontManager.shared.availableMembers(ofFontFamily: editorFontName)?.first,
           let postScriptName = member.first as? String,
           let font = NSFont(name: postScriptName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Every fixed-pitch font family installed on this Mac, so whichever
    /// coding font you already use is selectable.
    static let monospacedFamilies: [String] = {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies.filter { family in
            guard let members = manager.availableMembers(ofFontFamily: family) else { return false }
            return members.contains { member in
                guard member.count >= 4, let traits = member[3] as? NSNumber else { return false }
                return NSFontTraitMask(rawValue: UInt(traits.uintValue)).contains(.fixedPitchFontMask)
            }
        }
        .sorted()
    }()
}
