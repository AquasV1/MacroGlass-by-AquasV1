import Foundation

/// Every language the Script tab can run. Each case declares how it's
/// executed: a fixed system binary, a binary looked up on this Mac, or our
/// own built-in engine.
enum ScriptLanguage: String, CaseIterable, Codable, Identifiable {
    case bash
    case zsh
    case python3
    case node
    case appleScript
    case javascript
    case luau
    case autoHotkey

    var id: String { rawValue }

    enum Runtime {
        case fixed(String)     // ships with macOS
        case lookup(String)    // found on PATH, Homebrew, or installed by us
        case builtIn           // interpreted in-process
    }

    var displayName: String {
        switch self {
        case .bash: return "Bash"
        case .zsh: return "Zsh"
        case .python3: return "Python 3"
        case .node: return "Node.js"
        case .appleScript: return "AppleScript"
        case .javascript: return "JavaScript (JXA)"
        case .luau: return "Luau"
        case .autoHotkey: return "AutoHotkey"
        }
    }

    var fileExtension: String {
        switch self {
        case .bash, .zsh: return "sh"
        case .python3: return "py"
        case .node, .javascript: return "js"
        case .appleScript: return "applescript"
        case .luau: return "luau"
        case .autoHotkey: return "ahk"
        }
    }

    /// How a comment starts, so prepended libraries can label themselves
    /// without breaking the script they're prepended to.
    var commentPrefix: String {
        switch self {
        case .bash, .zsh, .python3: return "#"
        case .node, .javascript: return "//"
        case .appleScript: return "--"
        case .luau: return "--"
        case .autoHotkey: return ";"
        }
    }

    var runtime: Runtime {
        switch self {
        case .bash: return .fixed("/bin/bash")
        case .zsh: return .fixed("/bin/zsh")
        case .python3: return .lookup("python3")
        case .node: return .lookup("node")
        case .appleScript, .javascript: return .fixed("/usr/bin/osascript")
        case .luau: return .lookup("luau")
        case .autoHotkey: return .builtIn
        }
    }

    func arguments(scriptURL: URL) -> [String] {
        switch self {
        case .javascript: return ["-l", "JavaScript", scriptURL.path]
        default: return [scriptURL.path]
        }
    }

    /// Shown in Settings → Toolchains when the interpreter is missing.
    var installHint: String? {
        switch self {
        case .luau: return "Install fetches the official macOS build from the Luau releases page."
        case .node: return "Install Node.js with `brew install node`, or from nodejs.org."
        case .python3: return "Python 3 comes with the Xcode command line tools: `xcode-select --install`."
        default: return nil
        }
    }

    /// Recognized when opening a file from disk.
    static func forFileExtension(_ ext: String) -> ScriptLanguage? {
        switch ext.lowercased() {
        case "sh", "bash": return .bash
        case "zsh": return .zsh
        case "py": return .python3
        case "js", "mjs": return .node
        case "applescript", "scpt": return .appleScript
        case "luau", "lua": return .luau
        case "ahk": return .autoHotkey
        default: return nil
        }
    }

    var starterTemplate: String {
        switch self {
        case .bash, .zsh:
            return "echo \"Hello from MacroGlass\"\n"
        case .python3:
            return "print(\"Hello from MacroGlass\")\n"
        case .node, .javascript:
            return "console.log(\"Hello from MacroGlass\")\n"
        case .appleScript:
            return "display notification \"Hello from MacroGlass\"\n"
        case .luau:
            return """
            -- Luau
            local function greet(name: string): string
                return `Hello, {name}!`
            end

            print(greet("MacroGlass"))

            """
        case .autoHotkey:
            return """
            ; AutoHotkey — built-in engine
            ; Send, Click, MouseMove, Sleep, MsgBox, Run, Loop and %variables%

            name := MacroGlass

            Sleep, 400
            Send, Hello from %name%{Enter}

            Loop, 2
            {
                Sleep, 200
                Send, line{Enter}
            }

            """
        }
    }

    /// True for every template, so switching languages can swap starters
    /// without clobbering real work.
    static func isStarterTemplate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return allCases.contains {
            $0.starterTemplate.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }
}
