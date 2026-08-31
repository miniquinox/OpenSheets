import Foundation
import SheetModel

/// What the on-device model is allowed to know and do — stated as a protocol, not as a reference
/// to the document, and that choice is the whole architecture of this target.
///
/// The obvious wiring would hand the tools a `DocumentModel`. It would also be wrong three ways:
/// this target would then depend on `DocumentCore` (which already depends on half the package,
/// putting the model logic at the top of the graph where nothing can test it cheaply); the tools
/// would see every public thing a document can do rather than the four things a chat needs; and
/// the tests would need a real session, a real file and a real watcher to ask "does the read tool
/// truncate at the cap". A four-method protocol keeps the surface auditable — what the model can
/// reach is this file, in its entirety — and lets `SheetChatTests` drive every tool with a fake.
///
/// `@MainActor` because the live workbook belongs to the main actor (PLAN.md §2.3) and the
/// methods read and mutate it. Tool calls arrive on the concurrent executor and hop here through
/// the isolation, which serialises them against the user's own edits — the same cell cannot be
/// half-typed and half-written.
@MainActor
public protocol ChatDocument: AnyObject, Sendable {
    /// The trusted frame around every exchange: file name, sheets, selection, stats.
    func overview() -> ChatWorkbookOverview

    /// A rectangular window of display values. Implementations clamp to `maxRows`/`maxColumns`
    /// and report what fell off, rather than trusting the caller's arithmetic.
    func readRange(
        sheetName: String?, rangeA1: String, maxRows: Int, maxColumns: Int
    ) throws -> ChatRangeSlice

    /// Applies cell edits as **one undo step**, through the same parse path as typing.
    func applyEdits(_ edits: [ChatCellEdit], sheetName: String?) throws -> ChatEditOutcome

    /// Where something is, not what it says — mirrors the MCP `find` contract.
    func find(_ query: String, maxMatches: Int) -> ChatFindResult

    /// Computes a formula against the live workbook without writing anything, and returns the
    /// result rendered as text — a number, `TRUE`, an error token like `#NAME?`, or a sentence
    /// for a formula the engine cannot evaluate. The model's calculator: it exists so that
    /// "what do these add up to" is never answered by a 3B network's mental arithmetic, and
    /// never by a write.
    func evaluate(_ formulaSource: String) throws -> String
}

/// The trusted context line the controller writes ahead of each prompt.
///
/// Everything here except `headerCells` is *structural* — ranges, counts, names of things the
/// user chose — and goes to the model as plain trusted text. `headerCells` came out of row 1 of
/// the sheet, so the controller wraps it in the untrusted envelope like any other cell text.
public struct ChatWorkbookOverview: Sendable, Hashable {
    public var fileName: String
    public var sheetNames: [String]
    public var activeSheetName: String
    /// `A1:F42`, or `nil` for an empty sheet.
    public var usedRangeA1: String?
    public var selectionA1: String
    /// `Average 162,005 · Count 6 · Sum 972,029`, pre-formatted like the stats pill's values,
    /// and for the same reason: only the document knows the number format.
    public var selectionStatsLine: String?
    /// Row 1 of the active sheet, capped by the implementation. Untrusted — it is cell text.
    public var headerCells: [String]
    public var isEditable: Bool

    public init(
        fileName: String,
        sheetNames: [String],
        activeSheetName: String,
        usedRangeA1: String?,
        selectionA1: String,
        selectionStatsLine: String?,
        headerCells: [String],
        isEditable: Bool
    ) {
        self.fileName = fileName
        self.sheetNames = sheetNames
        self.activeSheetName = activeSheetName
        self.usedRangeA1 = usedRangeA1
        self.selectionA1 = selectionA1
        self.selectionStatsLine = selectionStatsLine
        self.headerCells = headerCells
        self.isEditable = isEditable
    }
}

/// One window of cells, rendered the way the MCP renders them — `CellText.plain`'s numbers
/// without separators, dates as ISO-8601 — because the next thing a model does with a value is
/// compare or compute, and both agent doors must describe a cell identically or the terminal
/// and the bubble give two answers about one sheet.
public struct ChatRangeSlice: Sendable, Hashable {
    public var sheetName: String
    /// The window actually read, after clamping — `B2:D25`, never a lie about coverage.
    public var rangeA1: String
    /// `["B", "C", "D"]`, for the TSV header line.
    public var columnLetters: [String]
    public var rows: [ChatRowSlice]
    /// Rows and columns the caps cut off. Zero means the read was complete.
    public var truncatedRowCount: Int
    public var truncatedColumnCount: Int

    public init(
        sheetName: String,
        rangeA1: String,
        columnLetters: [String],
        rows: [ChatRowSlice],
        truncatedRowCount: Int = 0,
        truncatedColumnCount: Int = 0
    ) {
        self.sheetName = sheetName
        self.rangeA1 = rangeA1
        self.columnLetters = columnLetters
        self.rows = rows
        self.truncatedRowCount = truncatedRowCount
        self.truncatedColumnCount = truncatedColumnCount
    }
}

/// One row of a slice: the 1-based row number and one display string per column.
public struct ChatRowSlice: Sendable, Hashable {
    public var number: Int
    public var cells: [String]

    public init(number: Int, cells: [String]) {
        self.number = number
        self.cells = cells
    }
}

/// One cell the model wants to change. `content` goes through the same input parsing as typing:
/// `=` means formula, and a formula that does not parse is refused, not written.
public struct ChatCellEdit: Sendable, Hashable {
    public var refA1: String
    public var content: String

    public init(refA1: String, content: String) {
        self.refA1 = refA1
        self.content = content
    }
}

/// What an edit batch actually did. `refusals` are sentences the model can read back to the
/// user — "F7: that formula does not parse" — because a refused write the model does not hear
/// about becomes a confident claim that the sheet was changed.
public struct ChatEditOutcome: Sendable, Hashable {
    public var appliedCount: Int
    /// The bounding range of what changed, for the reply — `A1:B3`.
    public var appliedRangeA1: String?
    public var refusals: [String]

    public init(appliedCount: Int, appliedRangeA1: String?, refusals: [String]) {
        self.appliedCount = appliedCount
        self.appliedRangeA1 = appliedRangeA1
        self.refusals = refusals
    }
}

public struct ChatFindMatch: Sendable, Hashable {
    public var sheetName: String
    public var refA1: String

    public init(sheetName: String, refA1: String) {
        self.sheetName = sheetName
        self.refA1 = refA1
    }
}

public struct ChatFindResult: Sendable, Hashable {
    public var matches: [ChatFindMatch]
    public var truncated: Bool

    public init(matches: [ChatFindMatch], truncated: Bool) {
        self.matches = matches
        self.truncated = truncated
    }
}
