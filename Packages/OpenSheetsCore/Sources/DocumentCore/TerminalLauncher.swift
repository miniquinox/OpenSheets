#if canImport(AppKit)
import AppKit
#endif
import Foundation

/// `Open terminal here`.
///
/// PLAN.md §12: opens Terminal or iTerm2 — whichever the user actually uses — at the workspace
/// root, with `claude` **typed but not executed**. The last clause is the whole design. Running a
/// command in somebody's shell because they clicked a button in a spreadsheet is not a feature,
/// and the difference between typing it and running it is the difference between an affordance and
/// a liberty.
@MainActor
public enum TerminalLauncher {
    /// The terminals we know how to drive, in preference order.
    public enum Terminal: String, Sendable, CaseIterable {
        case iTerm2 = "com.googlecode.iterm2"
        case terminal = "com.apple.Terminal"

        public var displayName: String {
            switch self {
            case .iTerm2: "iTerm"
            case .terminal: "Terminal"
            }
        }
    }

    /// Whichever terminal is the user's default, falling back to Terminal.app.
    ///
    /// "Default" here means the handler macOS would use for a `.command` file, which is the only
    /// registration a terminal actually makes. Asking that rather than looking for iTerm on disk
    /// is the difference between respecting a preference and guessing at one.
    public static func preferred() -> Terminal {
        #if canImport(AppKit)
        let probe = URL(fileURLWithPath: "/bin/zsh")
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
           let bundle = Bundle(url: handler)?.bundleIdentifier,
           let known = Terminal(rawValue: bundle)
        {
            return known
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Terminal.iTerm2.rawValue) != nil,
           UserDefaults.standard.bool(forKey: "OSPreferITerm")
        {
            return .iTerm2
        }
        #endif
        return .terminal
    }

    /// The AppleScript that opens `directory` and types `command` without pressing Return.
    ///
    /// Exposed rather than private because it is the part worth reading in review: there is no
    /// `do script` with a newline anywhere in it, and a test asserts that.
    public static func script(for terminal: Terminal, directory: URL, command: String) -> String {
        let path = directory.path(percentEncoded: false)
        let quotedPath = quoteForAppleScript(path)
        let quotedCommand = quoteForAppleScript(command)
        switch terminal {
        case .terminal:
            // `do script ""` opens a window and gives us a tab to talk to; `cd` runs (it is
            // navigation, not the user's command); the payload is *keystrokes*, so it lands on the
            // prompt unexecuted.
            return """
            tell application "Terminal"
                activate
                set newTab to do script ""
                do script "cd " & quoted form of \(quotedPath) & " && clear" in newTab
            end tell
            delay 0.2
            tell application "System Events"
                tell process "Terminal" to keystroke \(quotedCommand)
            end tell
            """
        case .iTerm2:
            return """
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow
                    write text "cd " & quoted form of \(quotedPath) & " && clear"
                end tell
            end tell
            delay 0.2
            tell application "System Events"
                tell process "iTerm2" to keystroke \(quotedCommand)
            end tell
            """
        }
    }

    /// Opens the terminal. Returns `false` when the script could not run — usually because
    /// automation permission has not been granted, which is a system prompt we cannot fake.
    @discardableResult
    public static func open(
        at directory: URL,
        typing command: String = "claude",
        terminal: Terminal? = nil
    ) -> Bool {
        #if canImport(AppKit)
        let target = terminal ?? preferred()
        guard let script = NSAppleScript(source: script(for: target, directory: directory, command: command))
        else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if error != nil {
            // Automation was refused, or the terminal is not installed. Opening the folder is a
            // worse answer than the one they asked for, and a much better one than nothing.
            NSWorkspace.shared.open(directory)
            return false
        }
        return true
        #else
        _ = (directory, command, terminal)
        return false
        #endif
    }

    /// AppleScript string literals escape only `\` and `"`.
    static func quoteForAppleScript(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }
}
