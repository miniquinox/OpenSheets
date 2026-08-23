import Foundation
import SheetModel

/// The shape every write tool's result takes.
///
/// One format across all of them, because an agent that has learned to read a `write_range`
/// result should not have to learn a second one for `insert_rows`. The three lines it always
/// carries are: **what happened**, **what changed**, and **how to undo it**.
///
/// The undo line is the point. An agent that has just been told *"snapshot 01JQ… taken before
/// this write"* can offer the user a one-call rollback without discovering the snapshot tools
/// first, which is the difference between a safety net and a safety net nobody finds.
public enum ResultFormatter {
    /// The diff line, with the snapshot pointer when there is one.
    public static func diffSummary(_ outcome: EditOutcome<some Sendable>) -> String {
        var lines: [String] = []
        if outcome.wrote {
            lines.append("saved · \(outcome.diff.summary)")
            if let snapshot = outcome.snapshotID {
                lines.append("undo: restore(path, \"\(snapshot.rawValue)\")")
            }
        } else {
            lines.append("preview only, nothing written · would change: \(outcome.diff.summary)")
        }
        if outcome.diff.wasTruncated {
            lines.append("(the change list was truncated; the counts above are still complete)")
        }
        return lines.joined(separator: "\n")
    }

    /// The first few changed cells, so a preview shows the actual edit rather than a count.
    ///
    /// Capped hard: a preview that dumps 5,000 cell changes has cost more context than making
    /// the change and looking at it would have.
    public static func changeDetail(
        _ diff: WorkbookDiff,
        styles: StyleTable,
        limit: Int = 12
    ) -> String? {
        var lines: [String] = []
        var shown = 0
        for sheetDiff in diff.sheetDiffs {
            for change in sheetDiff.cellChanges {
                guard shown < limit else { break }
                shown += 1
                let before = change.before.map { render($0, styles: styles) } ?? "(empty)"
                let after = change.after.map { render($0, styles: styles) } ?? "(empty)"
                lines.append("  \(sheetDiff.sheetName)!\(change.ref.a1String): \(before) → \(after)")
            }
        }
        guard !lines.isEmpty else { return nil }
        let total = diff.totalCellChangeCount
        if total > shown { lines.append("  … \(CellText.count(total - shown)) more") }
        return lines.joined(separator: "\n")
    }

    private static func render(_ cell: Cell, styles: StyleTable) -> String {
        if let formula = CellText.formula(cell) {
            return UntrustedContent.inlineCell(formula, limit: 60)
        }
        let text = CellText.plain(cell, styles: styles)
        return text.isEmpty ? "(empty)" : UntrustedContent.inlineCell(text, limit: 60)
    }

    /// A `notImplemented` refusal, said honestly.
    ///
    /// The Wave 2 addendum §4 is explicit that v0.1 refuses to add, remove or reorder a sheet
    /// rather than half-doing it — adding a part means patching `[Content_Types].xml`,
    /// `workbook.xml` and the relationships in agreement, and a partial job produces a file
    /// Excel calls damaged. An agent told *"not supported, here is what to do instead"* routes
    /// around it in one turn; an agent told *"error"* retries.
    public static func refusal(_ feature: String, alternative: String) -> ToolOutput {
        ToolOutput(
            "not supported in v0.1: \(feature)\n\(alternative)",
            isError: true
        )
    }
}
