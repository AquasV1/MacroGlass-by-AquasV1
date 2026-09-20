import Foundation

/// Finds the interpreters scripts need, and installs the ones that don't
/// ship with macOS into our own Application Support directory.
enum Toolchain {

    static var managedDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacroGlass", isDirectory: true)
            .appendingPathComponent("Toolchains", isDirectory: true)
    }

    /// Homebrew (both architectures), MacPorts, the usual system paths, and
    /// anything we installed ourselves.
    private static let searchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/bin"
    ]

    // Lookups can run off the main thread during a rescan; the cache is a
    // plain memo, so a torn read at worst costs one extra `which`.
    private nonisolated(unsafe) static var cache: [String: URL] = [:]

    static func clearCache() {
        cache.removeAll()
    }

    /// Resolves an executable name to a path, preferring our managed copy.
    static func resolve(_ name: String) -> URL? {
        if let cached = cache[name], FileManager.default.isExecutableFile(atPath: cached.path) {
            return cached
        }

        let fileManager = FileManager.default
        let managed = managedDirectory.appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: managed.path) {
            cache[name] = managed
            return managed
        }

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                cache[name] = candidate
                return candidate
            }
        }

        // Last resort: a login shell, which picks up nvm, pyenv, asdf and
        // anything else that only exists in the user's PATH.
        if let found = viaLoginShell(name) {
            cache[name] = found
            return found
        }

        return nil
    }

    static func resolve(_ language: ScriptLanguage) -> URL? {
        switch language.runtime {
        case .fixed(let path):
            let url = URL(fileURLWithPath: path)
            return FileManager.default.isExecutableFile(atPath: path) ? url : nil
        case .lookup(let name):
            return resolve(name)
        case .builtIn:
            return nil
        }
    }

    /// Wine, for running a real AutoHotkey.exe.
    static func resolveWine() -> URL? {
        for name in ["wine64", "wine", "wine-stable"] {
            if let url = resolve(name) { return url }
        }
        return nil
    }

    private static func viaLoginShell(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              FileManager.default.isExecutableFile(atPath: raw) else { return nil }

        return URL(fileURLWithPath: raw)
    }

    /// Runs a command without blocking the caller's thread.
    @discardableResult
    static func runProcess(_ executable: URL, _ arguments: [String]) async -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

// MARK: - Installing

enum ToolchainError: LocalizedError {
    case downloadFailed(String)
    case unpackFailed(String)
    case missingBinary(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail): return "Download failed: \(detail)"
        case .unpackFailed(let detail): return "Could not unpack: \(detail)"
        case .missingBinary(let name): return "\(name) wasn't in the downloaded archive."
        }
    }
}

enum ToolchainInstaller {

    /// Luau publishes a prebuilt macOS bundle with every release — grab it,
    /// unpack it into our managed directory, and make it runnable.
    static let luauReleaseURL = URL(string: "https://github.com/luau-lang/luau/releases/latest/download/luau-macos.zip")!

    static func installLuau(log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        let destination = Toolchain.managedDirectory

        log("Downloading the latest Luau release…")
        let (downloadedURL, response) = try await URLSession.shared.download(from: luauReleaseURL)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ToolchainError.downloadFailed("HTTP \(http.statusCode)")
        }

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("luau-macos-\(UUID().uuidString).zip")
        try? fileManager.removeItem(at: archiveURL)
        try fileManager.moveItem(at: downloadedURL, to: archiveURL)
        defer { try? fileManager.removeItem(at: archiveURL) }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        log("Unpacking…")
        let unzip = await Toolchain.runProcess(
            URL(fileURLWithPath: "/usr/bin/unzip"),
            ["-o", archiveURL.path, "-d", destination.path]
        )
        guard unzip.exitCode == 0 else {
            throw ToolchainError.unpackFailed(unzip.output)
        }

        let binary = destination.appendingPathComponent("luau")
        guard fileManager.fileExists(atPath: binary.path) else {
            throw ToolchainError.missingBinary("luau")
        }

        log("Making it runnable…")
        // chmod, drop the quarantine flag, and ad-hoc sign — Apple silicon
        // refuses to execute an unsigned binary outright.
        await Toolchain.runProcess(URL(fileURLWithPath: "/bin/chmod"), ["+x", binary.path])
        await Toolchain.runProcess(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", destination.path])
        await Toolchain.runProcess(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", binary.path])

        // The release also ships luau-compile and luau-analyze; sign those
        // too so they're usable from a terminal.
        for extra in ["luau-compile", "luau-analyze"] {
            let url = destination.appendingPathComponent(extra)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            await Toolchain.runProcess(URL(fileURLWithPath: "/bin/chmod"), ["+x", url.path])
            await Toolchain.runProcess(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", url.path])
        }

        Toolchain.clearCache()

        let check = await Toolchain.runProcess(binary, ["--version"])
        log(check.exitCode == 0
            ? "Installed \(check.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            : "Installed, but `luau --version` returned \(check.exitCode).")

        return binary
    }
}
