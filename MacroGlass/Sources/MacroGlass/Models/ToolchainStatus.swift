import Foundation
import Combine

/// Tracks which interpreters are present on this Mac, and runs the Luau
/// installer. Owned by the Settings tab.
@MainActor
final class ToolchainStatus: ObservableObject {
    @Published private(set) var paths: [ScriptLanguage: String] = [:]
    @Published private(set) var winePath: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var installLog = ""

    /// Resolving can spawn a login shell per missing tool, so the scan runs
    /// off the main thread and only the results come back to it.
    func refresh() {
        Task {
            let scan = await Self.scan()
            paths = scan.paths
            winePath = scan.wine
        }
    }

    nonisolated private static func scan() async -> (paths: [ScriptLanguage: String], wine: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                Toolchain.clearCache()
                var found: [ScriptLanguage: String] = [:]
                for language in ScriptLanguage.allCases {
                    if case .builtIn = language.runtime { continue }
                    if let url = Toolchain.resolve(language) {
                        found[language] = url.path
                    }
                }
                continuation.resume(returning: (found, Toolchain.resolveWine()?.path))
            }
        }
    }

    func path(for language: ScriptLanguage) -> String? {
        paths[language]
    }

    func isInstalled(_ language: ScriptLanguage) -> Bool {
        if case .builtIn = language.runtime { return true }
        return paths[language] != nil
    }

    func installLuau() {
        guard !isInstalling else { return }
        isInstalling = true
        installLog = "Starting…"

        Task { @MainActor in
            do {
                _ = try await ToolchainInstaller.installLuau { message in
                    Task { @MainActor in self.installLog = message }
                }
            } catch {
                installLog = error.localizedDescription
            }
            isInstalling = false
            refresh()
        }
    }
}
