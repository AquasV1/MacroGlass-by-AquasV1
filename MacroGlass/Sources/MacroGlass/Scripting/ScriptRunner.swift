import Foundation

/// Writes script text to a temp file and runs it with the right
/// interpreter, capturing stdout/stderr. AutoHotkey is the exception —
/// it's interpreted in-process by AHKInterpreter.
enum ScriptRunner {

    struct RunResult {
        let output: String
        let error: String
        let exitCode: Int32
        /// How many lines of library code sit in front of the script, so
        /// the console can say what an interpreter's line numbers mean.
        var libraryLineOffset: Int = 0
        var timedOut: Bool = false
        var duration: TimeInterval = 0
    }

    struct RunOptions {
        var ahkMapsControlToCommand: Bool = true
        var ahkExecutablePath: String = ""
        /// 0 leaves a script to run as long as it likes.
        var timeoutSeconds: Int = 0
        var workingDirectory: String = ""
        /// Prepended to PATH, so scripts can find tools the app can.
        var extraPATH: String = ""
        var environment: [String: String] = [:]
    }

    // MARK: - Entry points

    /// The built-in-language path, kept for callers that don't deal in
    /// custom languages.
    static func run(
        language: ScriptLanguage,
        content: String,
        options: RunOptions = RunOptions()
    ) async -> RunResult {
        await run(choice: LanguageChoice(language), content: content, libraries: [], options: options)
    }

    static func run(
        choice: LanguageChoice,
        content: String,
        libraries: [ScriptLibrary],
        options: RunOptions = RunOptions()
    ) async -> RunResult {
        let started = Date()
        let composed = compose(content: content, libraries: libraries, choice: choice)

        // AutoHotkey runs in-process on our own engine.
        if let builtIn = choice.builtIn, case .builtIn = builtIn.runtime {
            var result = await AHKInterpreter.run(source: composed.text, options: options)
            result.libraryLineOffset = composed.offset
            result.duration = Date().timeIntervalSince(started)
            return result
        }

        guard let executable = resolveExecutable(for: choice) else {
            return RunResult(
                output: "",
                error: missingMessage(for: choice),
                exitCode: 127,
                libraryLineOffset: composed.offset,
                duration: Date().timeIntervalSince(started)
            )
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macroglass-\(UUID().uuidString)")
            .appendingPathExtension(choice.fileExtension.isEmpty ? "txt" : choice.fileExtension)

        do {
            try composed.text.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return RunResult(
                output: "",
                error: "Could not write script: \(error.localizedDescription)",
                exitCode: -1,
                libraryLineOffset: composed.offset,
                duration: Date().timeIntervalSince(started)
            )
        }

        var result = await launch(
            executable: executable,
            arguments: arguments(for: choice, scriptURL: tempURL),
            options: options
        )
        try? FileManager.default.removeItem(at: tempURL)

        result.libraryLineOffset = composed.offset
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    // MARK: - Resolving

    private static func resolveExecutable(for choice: LanguageChoice) -> URL? {
        if let custom = choice.custom {
            let trimmed = custom.interpreter.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                let expanded = (trimmed as NSString).expandingTildeInPath
                return FileManager.default.isExecutableFile(atPath: expanded)
                    ? URL(fileURLWithPath: expanded)
                    : nil
            }
            return Toolchain.resolve(trimmed)
        }
        if let builtIn = choice.builtIn {
            return Toolchain.resolve(builtIn)
        }
        return nil
    }

    private static func arguments(for choice: LanguageChoice, scriptURL: URL) -> [String] {
        if let custom = choice.custom {
            return custom.resolvedArguments(scriptURL: scriptURL)
        }
        if let builtIn = choice.builtIn {
            return builtIn.arguments(scriptURL: scriptURL)
        }
        return [scriptURL.path]
    }

    private static func missingMessage(for choice: LanguageChoice) -> String {
        if let custom = choice.custom {
            return "“\(custom.interpreter)” isn't on this Mac, or isn't executable.\n"
                + "Settings → Languages is where its path is set."
        }
        let hint = choice.builtIn?.installHint.map { " \($0)" } ?? ""
        return "\(choice.displayName) isn't installed on this Mac.\(hint)\nSettings → Toolchains has an installer."
    }

    // MARK: - Libraries

    /// Pastes every applicable library in front of the script and reports
    /// how many lines that added.
    static func compose(
        content: String,
        libraries: [ScriptLibrary],
        choice: LanguageChoice
    ) -> (text: String, offset: Int) {
        let applicable = libraries.filter { $0.applies(to: choice.id) }
        guard !applicable.isEmpty else { return (content, 0) }

        let comment = choice.commentPrefix.isEmpty ? "#" : choice.commentPrefix
        var pieces: [String] = []
        for library in applicable {
            pieces.append("\(comment) ── MacroGlass library: \(library.name) ──")
            pieces.append(library.content)
        }
        pieces.append("\(comment) ── end of libraries ──")

        let preamble = pieces.joined(separator: "\n") + "\n"
        let offset = preamble.components(separatedBy: "\n").count - 1
        return (preamble + content, offset)
    }

    // MARK: - Running a process

    /// Output is drained as it arrives rather than after the process exits.
    /// Reading only in the termination handler deadlocks the moment a
    /// script writes more than a pipe buffer's worth, because the script
    /// blocks on a full pipe and never reaches exit.
    private static func launch(
        executable: URL,
        arguments: [String],
        options: RunOptions
    ) async -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(for: options)

        let workingDirectory = options.workingDirectory.trimmingCharacters(in: .whitespaces)
        if !workingDirectory.isEmpty {
            let expanded = (workingDirectory as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                process.currentDirectoryURL = URL(fileURLWithPath: expanded)
            }
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuffer = DataBuffer()
        let errBuffer = DataBuffer()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBuffer.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBuffer.append(chunk) }
        }

        let timedOut = Flag()

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                // The process is gone, so these can't block — they just
                // collect whatever landed between the last chunk and exit.
                outBuffer.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errBuffer.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                let wasKilled = timedOut.isSet
                var error = errBuffer.string
                if wasKilled {
                    let note = "Stopped after \(options.timeoutSeconds)s — the timeout in Settings → Script execution."
                    error = error.isEmpty ? note : error + "\n" + note
                }

                continuation.resume(returning: RunResult(
                    output: outBuffer.string,
                    error: error,
                    exitCode: wasKilled ? 124 : finished.terminationStatus,
                    timedOut: wasKilled
                ))
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: RunResult(
                    output: "",
                    error: "Failed to launch \(executable.path): \(error.localizedDescription)",
                    exitCode: -1
                ))
                return
            }

            if options.timeoutSeconds > 0 {
                let deadline = DispatchTime.now() + .seconds(options.timeoutSeconds)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                    // SIGTERM is a request; give it a moment, then insist.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    private static func environment(for options: RunOptions) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        let extra = options.extraPATH.trimmingCharacters(in: .whitespaces)
        let base = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        // Homebrew's bin directories are where most interpreters live and
        // a GUI app doesn't inherit them, so they go on by default.
        var segments = extra.isEmpty ? [] : extra.components(separatedBy: ":")
        segments.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin"])
        segments.append(Toolchain.managedDirectory.path)
        segments.append(contentsOf: base.components(separatedBy: ":"))

        var seen = Set<String>()
        let deduped = segments.filter { segment in
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed).inserted
        }
        env["PATH"] = deduped.joined(separator: ":")

        for (key, value) in options.environment {
            env[key] = value
        }
        return env
    }
}

// MARK: - Small thread-safe boxes

/// Pipe reads land on a private queue while the continuation is resumed on
/// another, so the buffer needs a lock rather than a bare `var`.
private final class DataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
