import Foundation

/// Feature flags, read from `UserDefaults` (PLAN.md §11).
///
/// The point is that unfinished work ships **dark** rather than blocking a release. A half-done
/// formula engine behind `OSFlagFormulaEngine` costs nothing; a half-done formula engine on the
/// critical path holds up everyone else's work.
///
/// Every flag defaults to `false` except ``autoRefresh``, which defaults to `true` because it
/// is the core loop the app exists for (PLAN.md §1.2) and shipping it off would mean shipping
/// the product off.
///
/// Read these fresh each time rather than caching. `defaults write com.quino.opensheets
/// OSFlagEditing -bool YES` should take effect at the next check, not at the next launch —
/// that is what makes them useful while developing.
public enum Flags {
    /// Cell editing, undo, and save. Off until A8 wires the write path end to end.
    public static var editing: Bool { bool("OSFlagEditing") }

    /// The MCP server handshake and the Claude panel's live status.
    public static var mcp: Bool { bool("OSFlagMCP") }

    /// Evaluating formulas rather than only displaying their cached results.
    public static var formulaEngine: Bool { bool("OSFlagFormulaEngine") }

    /// Taking gzipped snapshots before every external refresh and every save.
    public static var snapshots: Bool { bool("OSFlagSnapshots") }

    /// Reloading automatically when the file changes on disk and there are no local edits.
    ///
    /// **Defaults to `true`.** With it off the app still notices the change and offers a
    /// refresh; it just waits for ⌘R (PLAN.md §6.3's `STALE` state).
    public static var autoRefresh: Bool { bool("OSFlagAutoRefresh", default: true) }

    /// Verbose signposts and timing output. Never on in a release build.
    public static var diagnostics: Bool { bool("OSFlagDiagnostics") }

    private static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    /// Every flag and its current value, for the launch screen and bug reports.
    public static var summary: String {
        let states = [
            ("editing", editing), ("mcp", mcp), ("formulaEngine", formulaEngine),
            ("snapshots", snapshots), ("autoRefresh", autoRefresh), ("diagnostics", diagnostics),
        ]
        return states.map { "\($0.0)=\($0.1 ? "on" : "off")" }.joined(separator: " ")
    }
}
