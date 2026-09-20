import Cocoa

/// AutoHotkey is Windows-only, so this runs a practical subset of AHK
/// natively by translating its commands into the same CGEvent calls the
/// macro player uses: Send, Click, MouseMove, Sleep, MsgBox, Run, Loop and
/// simple variables.
///
/// If you point Settings at a real AutoHotkey.exe and have Wine installed,
/// scripts are handed to the real thing instead and this engine steps out
/// of the way.
enum AHKInterpreter {

    static func run(source: String, options: ScriptRunner.RunOptions) async -> ScriptRunner.RunResult {
        if !options.ahkExecutablePath.isEmpty, let wine = Toolchain.resolveWine() {
            return await runUnderWine(source: source, autoHotkeyPath: options.ahkExecutablePath, wine: wine)
        }

        guard AccessibilityPermission.isTrusted else {
            return ScriptRunner.RunResult(
                output: "",
                error: "AutoHotkey scripts drive the keyboard and mouse, which needs Accessibility access. Grant it in the Record tab, then try again.",
                exitCode: 126
            )
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var machine = Machine(options: options)
                machine.run(lines: source.components(separatedBy: .newlines), firstLineNumber: 1)
                continuation.resume(returning: machine.result())
            }
        }
    }

    // MARK: - Wine passthrough

    private static func runUnderWine(source: String, autoHotkeyPath: String, wine: URL) async -> ScriptRunner.RunResult {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macroglass-\(UUID().uuidString).ahk")
        do {
            try source.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return ScriptRunner.RunResult(output: "", error: error.localizedDescription, exitCode: -1)
        }
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let run = await Toolchain.runProcess(wine, [autoHotkeyPath, scriptURL.path])
        return ScriptRunner.RunResult(
            output: run.exitCode == 0 ? run.output : "",
            error: run.exitCode == 0 ? "" : run.output,
            exitCode: run.exitCode
        )
    }

    // MARK: - The interpreter

    private struct Machine {
        let options: ScriptRunner.RunOptions
        var transcript: [String] = []
        var problems: [String] = []
        var variables: [String: String] = [:]
        var stopped = false

        init(options: ScriptRunner.RunOptions) {
            self.options = options
        }

        func result() -> ScriptRunner.RunResult {
            ScriptRunner.RunResult(
                output: transcript.joined(separator: "\n"),
                error: problems.joined(separator: "\n"),
                exitCode: problems.isEmpty ? 0 : 1
            )
        }

        mutating func run(lines: [String], firstLineNumber: Int) {
            var index = 0

            while index < lines.count && !stopped {
                let lineNumber = firstLineNumber + index
                let raw = lines[index]
                index += 1

                guard let statement = Self.clean(raw) else { continue }

                // Hotkey definitions need a persistent listener, which a
                // one-shot run can't provide.
                if statement.hasSuffix("::") {
                    problems.append("Line \(lineNumber): hotkey definitions (\(statement)) only work with a running listener — record a macro instead.")
                    continue
                }

                let (command, argument) = Self.split(statement)
                let expanded = expand(argument)

                switch command.lowercased() {
                case "send", "sendinput", "sendevent", "sendplay":
                    sendSequence(expanded)
                    transcript.append("\(lineNumber)  Send \(expanded)")

                case "sendtext", "sendraw":
                    AHKInterpreter.type(expanded)
                    transcript.append("\(lineNumber)  SendText \(expanded)")

                case "sleep":
                    let ms = Double(expanded.trimmingCharacters(in: .whitespaces)) ?? 0
                    Thread.sleep(forTimeInterval: max(0, ms) / 1000)
                    transcript.append("\(lineNumber)  Sleep \(Int(ms))ms")

                case "click":
                    let parts = Self.numbers(in: expanded)
                    let isRight = expanded.lowercased().contains("right")
                    if parts.count >= 2 {
                        AHKInterpreter.click(at: CGPoint(x: parts[0], y: parts[1]), rightButton: isRight)
                        transcript.append("\(lineNumber)  Click \(Int(parts[0])), \(Int(parts[1]))")
                    } else {
                        AHKInterpreter.click(at: nil, rightButton: isRight)
                        transcript.append("\(lineNumber)  Click")
                    }

                case "mousemove":
                    let parts = Self.numbers(in: expanded)
                    guard parts.count >= 2 else {
                        problems.append("Line \(lineNumber): MouseMove needs an x and y.")
                        continue
                    }
                    AHKInterpreter.move(to: CGPoint(x: parts[0], y: parts[1]))
                    transcript.append("\(lineNumber)  MouseMove \(Int(parts[0])), \(Int(parts[1]))")

                case "mouseclick":
                    let parts = Self.numbers(in: expanded)
                    let isRight = expanded.lowercased().hasPrefix("right")
                    let point = parts.count >= 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
                    AHKInterpreter.click(at: point, rightButton: isRight)
                    transcript.append("\(lineNumber)  MouseClick")

                case "msgbox":
                    AHKInterpreter.showMessage(expanded)
                    transcript.append("\(lineNumber)  MsgBox \(expanded)")

                case "run":
                    let output = AHKInterpreter.shell(expanded)
                    transcript.append("\(lineNumber)  Run \(expanded)")
                    if !output.isEmpty { transcript.append("        \(output)") }

                case "loop":
                    let count = Int(Self.numbers(in: expanded).first ?? 0)
                    let (body, consumed) = Self.block(in: lines, startingAfter: index)
                    index += consumed
                    guard count > 0 else {
                        problems.append("Line \(lineNumber): Loop needs a repeat count (infinite loops aren't supported here).")
                        continue
                    }
                    transcript.append("\(lineNumber)  Loop \(count)")
                    for _ in 0..<count where !stopped {
                        run(lines: body, firstLineNumber: lineNumber + 1)
                    }

                case "return", "exitapp", "exit":
                    stopped = true
                    transcript.append("\(lineNumber)  \(command)")

                default:
                    if let (name, value) = Self.assignment(in: statement) {
                        variables[name] = expand(value)
                        transcript.append("\(lineNumber)  \(name) = \(variables[name] ?? "")")
                    } else {
                        problems.append("Line \(lineNumber): “\(command)” isn't supported by the built-in engine.")
                    }
                }
            }
        }

        // MARK: Helpers

        func expand(_ text: String) -> String {
            guard text.contains("%") else { return text }
            var result = text
            for (name, value) in variables {
                result = result.replacingOccurrences(of: "%\(name)%", with: value)
            }
            return result
        }

        mutating func sendSequence(_ sequence: String) {
            var pending: CGEventFlags = []
            var literal = ""
            var index = sequence.startIndex

            func flushLiteral() {
                guard !literal.isEmpty else { return }
                AHKInterpreter.type(literal)
                literal = ""
            }

            while index < sequence.endIndex {
                let character = sequence[index]

                switch character {
                case "^":
                    flushLiteral()
                    // Most AHK scripts use ^ for the "command" shortcut key,
                    // which is Command on macOS.
                    pending.insert(options.ahkMapsControlToCommand ? .maskCommand : .maskControl)
                    index = sequence.index(after: index)

                case "+":
                    flushLiteral()
                    pending.insert(.maskShift)
                    index = sequence.index(after: index)

                case "!":
                    flushLiteral()
                    pending.insert(.maskAlternate)
                    index = sequence.index(after: index)

                case "#":
                    flushLiteral()
                    pending.insert(.maskCommand)
                    index = sequence.index(after: index)

                case "{":
                    flushLiteral()
                    guard let close = sequence[index...].firstIndex(of: "}") else {
                        literal.append(character)
                        index = sequence.index(after: index)
                        continue
                    }
                    let inner = String(sequence[sequence.index(after: index)..<close])
                    apply(namedKey: inner, flags: pending)
                    pending = []
                    index = sequence.index(after: close)

                default:
                    if pending.isEmpty {
                        literal.append(character)
                    } else if let code = AHKKeyMap.code(for: String(character)) {
                        AHKInterpreter.stroke(code, flags: pending)
                        pending = []
                    } else {
                        literal.append(character)
                        pending = []
                    }
                    index = sequence.index(after: index)
                }
            }

            flushLiteral()
        }

        mutating func apply(namedKey: String, flags: CGEventFlags) {
            // `{Tab 3}` repeats, `{Enter}` doesn't.
            let pieces = namedKey.split(separator: " ")
            let name = String(pieces.first ?? "")
            let repeats = pieces.count > 1 ? (Int(pieces[1]) ?? 1) : 1

            guard let code = AHKKeyMap.code(for: name) else {
                problems.append("Unknown key {\(namedKey)}")
                return
            }

            for _ in 0..<max(1, repeats) {
                AHKInterpreter.stroke(code, flags: flags)
            }
        }

        // MARK: Parsing

        static func clean(_ raw: String) -> String? {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            guard !line.hasPrefix(";") else { return nil }
            guard !line.hasPrefix("#") else { return nil }   // directives: #NoEnv etc.
            guard line != "{", line != "}" else { return nil }

            if let commentRange = line.range(of: " ;") {
                line = String(line[..<commentRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            return line.isEmpty ? nil : line
        }

        static func split(_ statement: String) -> (command: String, argument: String) {
            if let comma = statement.firstIndex(of: ",") {
                let command = String(statement[..<comma]).trimmingCharacters(in: .whitespaces)
                let argument = String(statement[statement.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                return (command, argument)
            }
            if let space = statement.firstIndex(of: " ") {
                let command = String(statement[..<space]).trimmingCharacters(in: .whitespaces)
                let argument = String(statement[statement.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                return (command, argument)
            }
            return (statement, "")
        }

        static func numbers(in text: String) -> [CGFloat] {
            text.components(separatedBy: CharacterSet(charactersIn: ", "))
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { CGFloat($0) }
        }

        static func assignment(in statement: String) -> (String, String)? {
            if let range = statement.range(of: ":=") {
                let name = String(statement[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                var value = String(statement[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return name.isEmpty ? nil : (name, value)
            }
            if let range = statement.range(of: "="), !statement.contains("==") {
                let name = String(statement[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(statement[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return nil }
                return (name, value)
            }
            return nil
        }

        /// Collects a `{ … }` block, returning its lines and how many source
        /// lines to skip.
        static func block(in lines: [String], startingAfter index: Int) -> (body: [String], consumed: Int) {
            var cursor = index
            // Skip blank lines before the opening brace.
            while cursor < lines.count, lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
                cursor += 1
            }
            guard cursor < lines.count,
                  lines[cursor].trimmingCharacters(in: .whitespaces) == "{" else {
                // Single-statement loop body.
                guard cursor < lines.count else { return ([], cursor - index) }
                return ([lines[cursor]], cursor - index + 1)
            }

            var depth = 0
            var body: [String] = []
            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed == "{" {
                    depth += 1
                    if depth == 1 { cursor += 1; continue }
                } else if trimmed == "}" {
                    depth -= 1
                    if depth == 0 { cursor += 1; break }
                }
                body.append(lines[cursor])
                cursor += 1
            }
            return (body, cursor - index)
        }
    }

    // MARK: - Event posting

    private static func type(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private static func stroke(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.01)
    }

    private static func currentPointer() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func move(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func click(at point: CGPoint?, rightButton: Bool) {
        let target = point ?? currentPointer()
        if point != nil { move(to: target) }

        let source = CGEventSource(stateID: .hidSystemState)
        let button: CGMouseButton = rightButton ? .right : .left
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp

        CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: target, mouseButton: button)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02)
        CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: target, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private static func showMessage(_ text: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = text
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Key names

enum AHKKeyMap {
    /// US-layout virtual key codes for the characters and named keys AHK
    /// scripts reach for most.
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,

        "enter": 36, "return": 36, "tab": 48, "space": 49, "backspace": 51, "bs": 51,
        "delete": 51, "del": 117, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pgup": 116, "pgdn": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    static func code(for name: String) -> CGKeyCode? {
        codes[name.lowercased()]
    }
}
