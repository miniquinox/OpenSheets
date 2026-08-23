import Foundation

/// One cell that changed between two versions of a sheet.
public struct CellChange: Sendable, Hashable, Codable {
    /// What kind of change this is.
    ///
    /// Separating value from formula from style matters for presentation: the diff panel shows
    /// `D2  120 → 129.6` for a value change and something quieter for a reformat, and the
    /// grid's flash should not fire for a style-only difference.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case added
        case removed
        case valueChanged
        /// The formula text changed. The cached value may or may not have.
        case formulaChanged
        /// Only the style id changed.
        case styleChanged
    }

    /// Where the change happened.
    public var ref: CellRef
    /// The cell before, or `nil` when it was ``Kind/added``.
    public var before: Cell?
    /// The cell after, or `nil` when it was ``Kind/removed``.
    public var after: Cell?
    /// Which kind of difference this is. See ``Kind`` — the classification is ordered by what
    /// is most worth showing, not by which fields differ.
    public var kind: Kind

    public init(ref: CellRef, before: Cell?, after: Cell?, kind: Kind) {
        self.ref = ref
        self.before = before
        self.after = after
        self.kind = kind
    }

    /// Classifies a before/after pair. Returns `nil` when nothing changed.
    ///
    /// Order matters: added and removed first, then formula, then value, then style. A cell
    /// whose formula changed usually has a different cached value too, and reporting that as
    /// `valueChanged` would hide the interesting half.
    public static func classify(ref: CellRef, before: Cell?, after: Cell?) -> CellChange? {
        switch (before, after) {
        case (nil, nil):
            return nil
        case let (nil, .some(new)):
            return CellChange(ref: ref, before: nil, after: new, kind: .added)
        case let (.some(old), nil):
            return CellChange(ref: ref, before: old, after: nil, kind: .removed)
        case let (.some(old), .some(new)):
            guard old != new else { return nil }
            let kind: Kind = if old.formula != new.formula {
                .formulaChanged
            } else if old.value != new.value {
                .valueChanged
            } else {
                .styleChanged
            }
            return CellChange(ref: ref, before: old, after: new, kind: kind)
        }
    }
}

/// A whole-row or whole-column insertion or deletion, detected rather than inferred per cell.
///
/// The reason this type exists: inserting one row into a 10,000-row sheet moves 9,999 rows, and
/// reporting that as 9,999 changed cells produces a diff panel nobody can use. The sync engine
/// runs an LCS over ``CellStore/rowContentHash(_:)`` values first, so the result reads
/// *"inserted 1 row at 5"* (PLAN.md §6.4).
public struct StructuralChange: Sendable, Hashable, Codable {
    /// Which axis moved, and in which direction.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case insertedRows, deletedRows, insertedColumns, deletedColumns
    }

    /// See ``Kind``.
    public var kind: Kind
    /// 0-based index where the change starts.
    public var index: Int
    /// How many rows or columns.
    public var count: Int

    public init(kind: Kind, index: Int, count: Int) {
        self.kind = kind
        self.index = index
        self.count = count
    }

    /// A one-line summary for the diff panel: *"inserted 1 row at 5"*.
    public var summary: String {
        let unit = (kind == .insertedRows || kind == .deletedRows) ? "row" : "column"
        let position = (kind == .insertedRows || kind == .deletedRows)
            ? "\(index + 1)"
            : CellRef.columnLetters(index)
        let verb = (kind == .insertedRows || kind == .insertedColumns) ? "inserted" : "deleted"
        return "\(verb) \(count) \(unit)\(count == 1 ? "" : "s") at \(position)"
    }
}

/// What changed on one sheet.
///
/// Note the naming against PLAN.md: §5.1 and §6.4 use "SheetDiff" for the whole-workbook
/// result. Here that is ``WorkbookDiff``, and `SheetDiff` is the per-sheet part — because a
/// type called `SheetDiff` that describes a workbook is a trap somebody will fall into.
public struct SheetDiff: Sendable, Hashable, Codable {
    /// Matched on id first, so a renamed sheet is still recognised as the same sheet.
    public var sheetID: SheetID
    /// The sheet's name after the change, for display.
    public var sheetName: String

    /// Individual cell changes, capped at ``Limits/maxDiffCellChanges``.
    ///
    /// Row-major order. When the cap bites, ``omittedCellChangeCount`` carries the rest —
    /// which is why the counts below are separate fields rather than derived from this array.
    public var cellChanges: [CellChange]

    /// Detected row and column inserts and deletes.
    public var structuralChanges: [StructuralChange]

    /// Cell changes that did not fit in ``cellChanges``. The panel shows `+N more`.
    public var omittedCellChangeCount: Int

    /// Total cells added, whether or not they are listed.
    public var addedCount: Int
    /// Total cells removed.
    public var removedCount: Int
    /// Total cells whose value, formula, or style changed.
    public var changedCount: Int

    public init(
        sheetID: SheetID,
        sheetName: String,
        cellChanges: [CellChange] = [],
        structuralChanges: [StructuralChange] = [],
        omittedCellChangeCount: Int = 0,
        addedCount: Int = 0,
        removedCount: Int = 0,
        changedCount: Int = 0
    ) {
        self.sheetID = sheetID
        self.sheetName = sheetName
        self.cellChanges = cellChanges
        self.structuralChanges = structuralChanges
        self.omittedCellChangeCount = omittedCellChangeCount
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.changedCount = changedCount
    }

    /// Every cell touched, listed or not.
    public var totalCellChangeCount: Int { addedCount + removedCount + changedCount }

    /// Whether anything changed on this sheet.
    public var isEmpty: Bool { totalCellChangeCount == 0 && structuralChanges.isEmpty }

    /// The refs to flash in the grid after a refresh, from the changes actually listed.
    public var changedRefs: Set<CellRef> { Set(cellChanges.map(\.ref)) }
}

/// A sheet that was renamed between two versions.
public struct SheetRename: Sendable, Hashable, Codable {
    /// The sheet, which kept its id across the rename — that is how the rename was detected.
    public var id: SheetID
    /// The name it had.
    public var before: String
    /// The name it has now.
    public var after: String

    public init(id: SheetID, before: String, after: String) {
        self.id = id
        self.before = before
        self.after = after
    }
}

/// A sheet that appeared or disappeared.
public struct SheetSummary: Sendable, Hashable, Codable {
    /// The sheet's id in whichever version it existed in.
    public var id: SheetID
    /// Its name, for display.
    public var name: String
    /// Populated cells, so the panel can say *"added sheet 'Q4' with 320 cells"*.
    public var cellCount: Int

    public init(id: SheetID, name: String, cellCount: Int) {
        self.id = id
        self.name = name
        self.cellCount = cellCount
    }
}

/// Everything that changed between two versions of a workbook.
///
/// This is what PLAN.md calls `SheetDiff` at the workbook level. It drives three surfaces: the
/// refresh pill's counts, the diff panel's list, and the grid's post-refresh flash. It is also
/// what an MCP `write_range` returns, so an agent can see what its own edit actually did.
///
/// Computing one is `SheetStore`'s job; this is only the shape.
public struct WorkbookDiff: Sendable, Hashable, Codable {
    /// One entry per sheet present in both versions. A sheet with no changes may still appear,
    /// so check ``SheetDiff/isEmpty`` rather than treating presence as change.
    public var sheetDiffs: [SheetDiff]
    /// Sheets in the new version and not the old.
    public var addedSheets: [SheetSummary]
    /// Sheets in the old version and not the new.
    public var removedSheets: [SheetSummary]
    /// Sheets that kept their id and changed their name.
    public var renamedSheets: [SheetRename]

    /// Whether the diff itself was truncated — too many changes to enumerate at all.
    /// Distinct from a per-sheet cap: this means the comparison gave up.
    public var wasTruncated: Bool

    public init(
        sheetDiffs: [SheetDiff] = [],
        addedSheets: [SheetSummary] = [],
        removedSheets: [SheetSummary] = [],
        renamedSheets: [SheetRename] = [],
        wasTruncated: Bool = false
    ) {
        self.sheetDiffs = sheetDiffs
        self.addedSheets = addedSheets
        self.removedSheets = removedSheets
        self.renamedSheets = renamedSheets
        self.wasTruncated = wasTruncated
    }

    /// Nothing changed.
    public static let empty = WorkbookDiff()

    /// Whether the two versions are equivalent as far as the model is concerned.
    public var isEmpty: Bool {
        sheetDiffs.allSatisfy(\.isEmpty) && addedSheets.isEmpty && removedSheets.isEmpty && renamedSheets.isEmpty
    }

    /// Cells touched across every sheet.
    public var totalCellChangeCount: Int {
        sheetDiffs.reduce(0) { $0 + $1.totalCellChangeCount }
    }

    /// Sheets with at least one change.
    public var changedSheetCount: Int {
        sheetDiffs.count { !$0.isEmpty }
    }

    /// The refresh pill's line: *"1 sheet, 42 cells"*.
    ///
    /// Lives here rather than in the view so the pill, the session feed, and the MCP response
    /// all say the same thing.
    public var summary: String {
        var parts: [String] = []
        if !addedSheets.isEmpty { parts.append("\(addedSheets.count) sheet\(addedSheets.count == 1 ? "" : "s") added") }
        if !removedSheets
            .isEmpty { parts.append("\(removedSheets.count) sheet\(removedSheets.count == 1 ? "" : "s") removed") }
        if !renamedSheets.isEmpty { parts.append("\(renamedSheets.count) renamed") }

        let sheets = changedSheetCount
        let cells = totalCellChangeCount
        if cells > 0 {
            parts.append("\(sheets) sheet\(sheets == 1 ? "" : "s"), \(cells) cell\(cells == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "no changes" : parts.joined(separator: " · ")
    }

    /// The refs to flash per sheet after a refresh.
    public var flashSets: [SheetID: Set<CellRef>] {
        Dictionary(uniqueKeysWithValues: sheetDiffs.map { ($0.sheetID, $0.changedRefs) })
    }
}
