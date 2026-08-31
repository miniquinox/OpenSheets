import Foundation
import os

/// The chat's diagnostic channel — because "the model added one row and said twenty" is
/// invisible without one.
///
/// The transcript the user sees is the model's *narration*; what actually happened is the
/// sequence of tool calls, and until this file existed nothing recorded it. Now every turn
/// writes structure to unified logging under `com.opensheets.SheetChat`:
///
/// ```bash
/// log stream --predicate 'subsystem == "com.opensheets.SheetChat"' --level debug
/// ```
///
/// Two categories: `session` (turns, durations, errors, session lifecycle) and `tools` (each
/// call the model makes, with argument and result *shapes*). Counts, ranges, durations and tool
/// names are `.public` — they are structure, and structure is the diagnosis. Cell text, prompts
/// and results are **payloads**, and payloads only reach the log when
/// `OSFlagChatLogPayloads` is on:
///
/// ```bash
/// defaults write com.quino.opensheets OSFlagChatLogPayloads -bool YES
/// ```
///
/// That gate is deliberate rather than cautious boilerplate: cell content is the user's data
/// and PLAN.md §7.3 treats it as untrusted everywhere else; a log that quietly copied every
/// read range into a file on disk would be this feature's first privacy regression. Off, the
/// log still answers the questions that matter — *how many calls, which tool, how big, how
/// long, what failed*.
enum ChatLog {
    static let session = Logger(subsystem: "com.opensheets.SheetChat", category: "session")
    static let tools = Logger(subsystem: "com.opensheets.SheetChat", category: "tools")

    /// Read fresh each check, like every flag in this app: `defaults write` should take effect
    /// at the next message, not the next launch. Lives here rather than in `DocumentCore.Flags`
    /// because the dependency arrow points the other way.
    static var logsPayloads: Bool {
        UserDefaults.standard.object(forKey: "OSFlagChatLogPayloads") as? Bool ?? false
    }

    /// A payload line, or nothing — the gate lives in one place so no call site can forget it.
    static func payload(_ logger: Logger, _ label: @autoclosure () -> String, _ text: @autoclosure () -> String) {
        guard logsPayloads else { return }
        let evaluatedLabel = label()
        let evaluatedText = text()
        logger.debug("\(evaluatedLabel, privacy: .public): \(evaluatedText, privacy: .public)")
    }
}
