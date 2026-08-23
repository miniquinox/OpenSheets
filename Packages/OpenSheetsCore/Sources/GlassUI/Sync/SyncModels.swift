import Foundation
import SheetModel

/// What the pill says.
///
/// A plain value. Nothing in this package watches a file — A6 does that, A8 turns its state into
/// one of these. Keeping the pill ignorant of the watcher is what lets the gallery render every
/// variant of it, including the ones that are hard to provoke on a real file system.
public struct RefreshNotice: Sendable, Hashable {
    /// Which of the three signals this is. `.agent` for an ordinary external change, `.conflict`
    /// when there are unsaved local edits, `.failure` when the reload itself failed.
    public var signal: DS.SignalKind
    /// "Changed on disk", "Conflict", "Could not read the file".
    public var headline: String
    /// Sheets touched. `0` is legal — a rename with no cell changes.
    public var sheetCount: Int
    /// Cells touched.
    public var cellCount: Int
    /// Unsaved local edits. Non-zero means this is a conflict, whatever `signal` says.
    public var localEditCount: Int
    /// The keyboard shortcut for the primary action, already composed as glyphs (`"⌘R"`).
    /// Display only — the actual binding belongs to whoever owns the command.
    public var shortcut: String?
    /// Whether the watcher is running. A paused watcher gets a dimmed dot and says so.
    public var isWatching: Bool

    public init(
        signal: DS.SignalKind = .agent,
        headline: String = "Changed on disk",
        sheetCount: Int = 0,
        cellCount: Int = 0,
        localEditCount: Int = 0,
        shortcut: String? = "⌘R",
        isWatching: Bool = true
    ) {
        self.signal = signal
        self.headline = headline
        self.sheetCount = sheetCount
        self.cellCount = cellCount
        self.localEditCount = localEditCount
        self.shortcut = shortcut
        self.isWatching = isWatching
    }

    /// "1 sheet, 42 cells". Singular and plural are both spelled out; "1 sheets" in the app's
    /// signature moment would be the first thing anybody notices.
    public var detail: String {
        var parts: [String] = []
        if sheetCount > 0 { parts.append("\(sheetCount) \(sheetCount == 1 ? "sheet" : "sheets")") }
        if cellCount > 0 { parts.append("\(cellCount.formatted()) \(cellCount == 1 ? "cell" : "cells")") }
        if localEditCount > 0 {
            parts.append("\(localEditCount) unsaved \(localEditCount == 1 ? "edit" : "edits")")
        }
        return parts.joined(separator: ", ")
    }

    /// What VoiceOver reads for the whole pill, in one sentence.
    public var accessibilityLabel: String {
        detail.isEmpty ? headline : "\(headline). \(detail)."
    }
}

/// One cell that changed, as the diff shows it.
///
/// Values arrive pre-formatted as `String`. That is deliberate: the diff has to show `120 → 129.6`
/// using the cell's *own* number format, and only A8 knows the style table. A `CellValue` here
/// would push formatting into a design-system package that has no business doing it.
public struct CellChange: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case changed
        case added
        case removed

        /// The glyph in the leading column. Carries the kind for anyone who cannot rely on the
        /// before/after columns — a screen at arm's length, or a colour-blind reader.
        public var symbolName: String {
            switch self {
            case .changed: "arrow.triangle.2.circlepath"
            case .added: "plus"
            case .removed: "minus"
            }
        }

        public var label: String { rawValue }
    }

    public var sheetName: String
    public var ref: CellRef
    /// The value before the external change. Empty string for `.added`.
    public var before: String
    /// The value after. Empty string for `.removed`.
    public var after: String
    public var kind: Kind

    public init(sheetName: String, ref: CellRef, before: String, after: String, kind: Kind = .changed) {
        self.sheetName = sheetName
        self.ref = ref
        self.before = before
        self.after = after
        self.kind = kind
    }

    /// `Sheet1!D2` — stable across a re-diff, which matters because the panel stays open while
    /// the file changes again (PLAN.md §9).
    public var id: String { "\(sheetName)!\(A1Notation.format(sheetName: nil, ref: ref))" }

    /// `D2`, for the row's leading column.
    public var refLabel: String { A1Notation.format(sheetName: nil, ref: ref) }

    /// The em-dash placeholder, so an added cell's "before" column is not blank.
    public var beforeDisplay: String { before.isEmpty ? "—" : before }
    public var afterDisplay: String { after.isEmpty ? "—" : after }
}

/// Per-sheet counts, for the row of chips at the top of the panel.
public struct SheetChangeSummary: Sendable, Hashable, Identifiable {
    public var name: String
    public var changedCount: Int
    public var addedCount: Int
    public var removedCount: Int
    /// The sheet's old name, when the change *is* a rename.
    public var renamedFrom: String?

    public init(
        name: String,
        changedCount: Int = 0,
        addedCount: Int = 0,
        removedCount: Int = 0,
        renamedFrom: String? = nil
    ) {
        self.name = name
        self.changedCount = changedCount
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.renamedFrom = renamedFrom
    }

    public var id: String { name }
    public var totalCount: Int { changedCount + addedCount + removedCount }
}

/// Everything the diff panel shows.
public struct FileChangeSet: Sendable, Hashable {
    public var notice: RefreshNotice
    public var sheets: [SheetChangeSummary]
    public var changes: [CellChange]
    /// Rows the caller withheld. A 10,000-cell diff is not a list, it is a scroll bar — A8 caps
    /// the array and puts the remainder here so the panel can say `+ 9,750 more` honestly rather
    /// than pretending the list is complete.
    public var truncatedCount: Int
    /// Set when the file changed again while the panel was open (PLAN.md §9). The panel says so
    /// instead of silently swapping the rows under the reader's cursor.
    public var wasRediffed: Bool

    public init(
        notice: RefreshNotice,
        sheets: [SheetChangeSummary] = [],
        changes: [CellChange] = [],
        truncatedCount: Int = 0,
        wasRediffed: Bool = false
    ) {
        self.notice = notice
        self.sheets = sheets
        self.changes = changes
        self.truncatedCount = truncatedCount
        self.wasRediffed = wasRediffed
    }
}

/// Everything the pill and the panel can ask for. One enum for the whole flow, because it *is*
/// one flow — the pill and the panel are two shapes of the same surface.
public enum SyncAction: Sendable, Hashable {
    /// The pill was clicked: grow into the panel.
    case expand
    /// The panel's collapse control: shrink back to the pill.
    case collapse
    /// Apply the file's version. The primary action, and the one bound to ⌘R.
    case refresh
    /// Scroll the grid to this change and select it. Does not close the panel.
    case showInGrid(CellChange.ID)
    /// Throw away what is on disk and keep the in-memory workbook.
    case discardFileChanges
    /// Conflict only: overwrite the file with local edits.
    case keepMine
    /// Conflict only: throw away local edits and reload.
    case takeDisk
    /// Filter the row list. `nil` shows every sheet.
    case filterSheet(String?)
    /// Dismiss without deciding. The pill comes back on the next change.
    case dismiss
}
