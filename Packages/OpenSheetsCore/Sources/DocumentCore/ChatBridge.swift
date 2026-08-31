import Foundation
import SheetChat
import SheetFormula
import SheetMCP
import SheetModel

/// What ``DocumentModel/applyAssistantEdits(_:on:name:)`` actually did.
public struct AssistantEditOutcome: Sendable, Hashable {
    /// The cells that genuinely changed — no-op writes are dropped by `WorkbookEditor`.
    public var appliedRefs: [CellRef]
    /// Per-cell refusals, as sentences: "F7: that formula does not parse".
    public var refusals: [String]

    public init(appliedRefs: [CellRef], refusals: [String]) {
        self.appliedRefs = appliedRefs
        self.refusals = refusals
    }
}

/// The document was closed under a tool call that was still in flight.
struct DocumentClosedError: LocalizedError {
    var errorDescription: String? {
        "The document is no longer open."
    }
}

/// `SheetChat`'s window onto the **live** document.
///
/// This is the other half of the in-process decision documented on `SheetChatController`: the
/// MCP server reaches the file, this reaches the model the user is looking at. Reads come off
/// `DocumentModel.workbook` — unsaved edits included, because a chat that describes the file
/// instead of the screen is wrong within one keystroke. Writes go through
/// ``DocumentModel/applyAssistantEdits(_:on:name:)``, which is the typing pipeline batched:
/// parse, refuse bad formulas, one undo step, recalculation, and a flash on the changed cells.
///
/// Values are rendered with `SheetMCP`'s ``CellText``, not GridKit's formatter, and that reuse
/// is a policy, not a convenience: both agent doors must describe a cell the same way, or the
/// user gets one answer in the terminal and another in the bubble over the same sheet.
///
/// `weak` on the model because the retain chain runs the other way — document → controller →
/// tools → bridge — and a strong pointer here would keep every closed document alive for as
/// long as its chat existed.
@MainActor
public final class DocumentChatBridge: ChatDocument {
    private weak var model: DocumentModel?

    /// Row 1 columns offered as context. Ten covers real tables; past that the header line
    /// starts crowding out the question it frames.
    static let headerColumnCap = 10
    /// Cells `find` walks before giving up, `SelectionStatistics.cellBudget`'s reasoning at a
    /// tool's timescale: column A alone is a million cells and a chat reply must not eat them.
    static let findCellBudget = 200_000

    public init(model: DocumentModel) {
        self.model = model
    }

    public func overview() -> ChatWorkbookOverview {
        guard let model else {
            return ChatWorkbookOverview(
                fileName: "", sheetNames: [], activeSheetName: "", usedRangeA1: nil,
                selectionA1: "A1", selectionStatsLine: nil, headerCells: [], isEditable: false
            )
        }
        let workbook = model.workbook
        let sheet = workbook[model.activeSheetID]
        let used = sheet?.usedRange

        var headers: [String] = []
        if let sheet, let used {
            // Labelled `C: Revenue`, not bare `Revenue`: the observed failure mode is the model
            // *guessing* a column letter for a header it was told about — summing D because it
            // assumed, and reporting a confident 0. With the letter in the line, name→letter is
            // a lookup, not an inference.
            for column in used.columns.prefix(Self.headerColumnCap) {
                let cell = sheet.cells[CellRef(row: used.start.row, column: column)]
                let text = cell.map { Self.plain($0, in: workbook) } ?? ""
                headers.append(text.isEmpty ? "" : "\(CellRef.columnLetters(column)): \(text)")
            }
            // A header row of blanks frames nothing; spend the tokens on the question instead.
            if headers.allSatisfy(\.isEmpty) {
                headers = []
            }
        }

        // The pill's own formatted values, deliberately: the user asks about the numbers they
        // can see in the corner of the window, and those carry the column's format.
        let stats = model.selectionStats
        let statsLine = stats.displayed
            .map { "\($0.label) \(stats.values[$0] ?? "—")" }
            .joined(separator: " · ")

        return ChatWorkbookOverview(
            fileName: model.url.lastPathComponent,
            sheetNames: workbook.sheets.filter { $0.visibility == .visible }.map(\.name),
            activeSheetName: sheet?.name ?? "",
            usedRangeA1: used?.a1String(collapseSingleCell: false),
            // The A1 rectangle, not the stats pill's `41R × 3C` label — the same choice the
            // handshake makes, because this string goes straight back into `read_cells`.
            selectionA1: model.selection.activeRange.a1String(),
            selectionStatsLine: statsLine.isEmpty ? nil : statsLine,
            nextEmptyRow: used.map { $0.end.row + 2 },
            headerCells: headers,
            isEditable: model.isEditable
        )
    }

    public func readRange(
        sheetName: String?, rangeA1: String, maxRows: Int, maxColumns: Int
    ) throws -> ChatRangeSlice {
        guard let model else { throw DocumentClosedError() }
        let workbook = model.workbook
        let sheet = try resolveSheet(named: sheetName, in: model)
        guard let range = CellRange(a1: rangeA1.uppercased()) else {
            throw SheetError.invalidCellReference(text: rangeA1)
        }

        let lastRow = min(range.end.row, range.start.row + maxRows - 1)
        let lastColumn = min(range.end.column, range.start.column + maxColumns - 1)
        let window = CellRange(
            rows: range.start.row ... lastRow,
            columns: range.start.column ... lastColumn
        )

        // Truncation is counted against rows that *exist* — the model should chase the rest of
        // the data, not the million blank rows a whole-column range technically names.
        let used = sheet.usedRange
        let truncatedRows = max(0, min(range.end.row, used?.end.row ?? range.start.row) - lastRow)
        let truncatedColumns = max(
            0, min(range.end.column, used?.end.column ?? range.start.column) - lastColumn
        )

        var rows: [ChatRowSlice] = []
        for row in window.rows {
            var cells: [String] = []
            for column in window.columns {
                let cell = sheet.cells[CellRef(row: row, column: column)]
                cells.append(cell.map { Self.plain($0, in: workbook) } ?? "")
            }
            rows.append(ChatRowSlice(number: row + 1, cells: cells))
        }
        return ChatRangeSlice(
            sheetName: sheet.name,
            rangeA1: window.a1String(collapseSingleCell: false),
            columnLetters: window.columns.map { CellRef.columnLetters($0) },
            rows: rows,
            truncatedRowCount: truncatedRows,
            truncatedColumnCount: truncatedColumns
        )
    }

    public func applyEdits(_ edits: [ChatCellEdit], sheetName: String?) throws -> ChatEditOutcome {
        guard let model else { throw DocumentClosedError() }
        var sheetID: SheetID?
        if let sheetName {
            sheetID = try resolveSheet(named: sheetName, in: model).id
        }

        var resolved: [(ref: CellRef, text: String)] = []
        var refusals: [String] = []
        for edit in edits {
            guard let ref = CellRef(a1: edit.refA1.uppercased()) else {
                refusals.append("\(UntrustedContent.inlineCell(edit.refA1)): not a cell reference")
                continue
            }
            resolved.append((ref: ref, text: edit.content))
        }

        let outcome = model.applyAssistantEdits(resolved, on: sheetID)
        var applied: CellRange?
        if let firstRef = outcome.appliedRefs.first {
            let rows = outcome.appliedRefs.map(\.row)
            let columns = outcome.appliedRefs.map(\.column)
            applied = CellRange(
                rows: (rows.min() ?? firstRef.row) ... (rows.max() ?? firstRef.row),
                columns: (columns.min() ?? firstRef.column) ... (columns.max() ?? firstRef.column)
            )
        }
        return ChatEditOutcome(
            appliedCount: outcome.appliedRefs.count,
            appliedRangeA1: applied?.a1String(),
            refusals: refusals + outcome.refusals
        )
    }

    public func find(_ query: String, maxMatches: Int) -> ChatFindResult {
        guard let model else { return ChatFindResult(matches: [], truncated: false) }
        let workbook = model.workbook
        let needle = query.lowercased()

        // Active sheet first: "where is Total" almost always means the sheet on screen.
        var sheets = workbook.sheets.filter { $0.visibility == .visible }
        if let index = sheets.firstIndex(where: { $0.id == model.activeSheetID }), index != 0 {
            sheets.insert(sheets.remove(at: index), at: 0)
        }

        var matches: [ChatFindMatch] = []
        var truncated = false
        var walked = 0
        for sheet in sheets {
            guard let used = sheet.usedRange else { continue }
            var done = false
            sheet.cells.forEachCell(in: used) { ref, cell in
                guard !done else { return }
                walked += 1
                if walked > Self.findCellBudget {
                    truncated = true
                    done = true
                    return
                }
                guard !cell.isBlank else { return }
                let text = Self.plain(cell, in: workbook)
                let isHit = text.lowercased().contains(needle)
                    || cell.formula?.lowercased().contains(needle) == true
                if isHit {
                    matches.append(ChatFindMatch(sheetName: sheet.name, refA1: ref.a1String))
                    if matches.count >= maxMatches {
                        truncated = true
                        done = true
                    }
                }
            }
            if truncated {
                break
            }
        }
        return ChatFindResult(matches: matches, truncated: truncated)
    }

    public func appendRows(_ rows: [[String]]) throws -> ChatAppendOutcome {
        guard let model else { throw DocumentClosedError() }
        let sheet = try resolveSheet(named: nil, in: model)
        // Below the used range, starting at its leading column — an empty sheet appends at A1.
        // Every row of the batch lands in one applyAssistantEdits call: one undo step, one
        // flash, and a result the model cannot honestly misreport.
        let used = sheet.usedRange
        let firstRow = used.map { $0.end.row + 1 } ?? 0
        let startColumn = used?.start.column ?? 0
        var edits: [(ref: CellRef, text: String)] = []
        for (rowOffset, values) in rows.enumerated() {
            for (columnOffset, value) in values.enumerated() {
                edits.append((
                    ref: CellRef(row: firstRow + rowOffset, column: startColumn + columnOffset),
                    text: value
                ))
            }
        }
        let outcome = model.applyAssistantEdits(edits)
        return ChatAppendOutcome(
            firstRow: firstRow + 1,
            rowCount: rows.count,
            appliedCount: outcome.appliedRefs.count,
            refusals: outcome.refusals
        )
    }

    public func evaluate(_ formulaSource: String) throws -> String {
        guard let model else { throw DocumentClosedError() }
        let source = formulaSource.hasPrefix("=") ? String(formulaSource.dropFirst()) : formulaSource
        switch model.evaluateFormula(source) {
        case let .value(value):
            // Rendered like a read: the result of `=A1` is whatever text A1 holds, and text
            // from a cell is untrusted wherever it surfaces.
            return CellText.plain(
                Cell(value: value),
                styles: model.workbook.styles,
                dateSystem: model.workbook.meta.dateSystem
            )
        case let .keepCached(reason):
            return reason.message
        }
    }

    // MARK: - Helpers

    private func resolveSheet(named name: String?, in model: DocumentModel) throws -> Sheet {
        if let name {
            guard let sheet = model.workbook.sheet(named: name) else {
                throw SheetError.sheetNotFound(reference: name)
            }
            return sheet
        }
        guard let sheet = model.workbook[model.activeSheetID] else {
            throw SheetError.sheetNotFound(reference: "the active sheet")
        }
        return sheet
    }

    private static func plain(_ cell: Cell, in workbook: Workbook) -> String {
        CellText.plain(cell, styles: workbook.styles, dateSystem: workbook.meta.dateSystem)
    }
}
