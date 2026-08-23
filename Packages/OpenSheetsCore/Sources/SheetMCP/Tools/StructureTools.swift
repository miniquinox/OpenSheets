import Foundation
import SheetFormula
import SheetModel

/// `insert_rows`, `delete_rows`, `insert_columns`, `delete_columns`.
///
/// One implementation behind four schemas, because the only thing that differs is the axis and
/// the direction, and four copies of the formula-rewrite pass is four places for it to be
/// forgotten.
public enum StructureTools {
    public static let insertRows = make(
        name: "insert_rows",
        title: "Insert rows",
        axis: "rows",
        inserting: true,
        summary: """
        Inserts blank rows, shifting everything below down. **Every formula in the workbook is \
        rewritten** so it still points at the data it pointed at, including formulas on other \
        sheets and defined names; the result says how many were rewritten and how many became \
        #REF!. Note that conditional formats, data validation, charts and table ranges are \
        copied through verbatim and do *not* follow the insert (v0.1 limitation).
        """
    )

    public static let deleteRows = make(
        name: "delete_rows",
        title: "Delete rows",
        axis: "rows",
        inserting: false,
        summary: """
        Deletes rows, shifting everything below up. Formulas across the workbook are adjusted; \
        a formula that pointed at a deleted cell becomes #REF! rather than being quietly \
        repointed at whatever moved into that address. A snapshot is taken first — run with \
        `preview: true` if you are not certain of the row numbers.
        """
    )

    public static let insertColumns = make(
        name: "insert_columns",
        title: "Insert columns",
        axis: "columns",
        inserting: true,
        summary: """
        Inserts blank columns, shifting everything to the right. Formulas across the workbook \
        are adjusted, as are defined names and merged regions.
        """
    )

    public static let deleteColumns = make(
        name: "delete_columns",
        title: "Delete columns",
        axis: "columns",
        inserting: false,
        summary: """
        Deletes columns, shifting everything left. Formulas that referenced a deleted column \
        become #REF!. A snapshot is taken first.
        """
    )

    private static func make(
        name: String,
        title: String,
        axis: String,
        inserting: Bool,
        summary: String
    ) -> ToolDefinition {
        let isRowAxis = axis == "rows"
        return ToolDefinition(
            schema: ToolSchema(
                name: name,
                title: title,
                summary: summary,
                properties: [
                    ToolSchema.pathProperty,
                    ToolSchema.sheetProperty(required: false),
                    ToolProperty(
                        name: "at",
                        kind: .integer,
                        summary: isRowAxis
                            ? "1-based row number to \(inserting ? "insert before" : "start deleting at")."
                            : "Column, as a letter (`C`) is not accepted here — use the 1-based number, "
                            + "or `column` for a letter.",
                        isRequired: !isRowAxis ? false : true
                    ),
                    ToolProperty(
                        name: "column",
                        kind: .string,
                        summary: isRowAxis
                            ? "Unused for a row operation."
                            : "Column letter, e.g. `C`. An alternative to `at`."
                    ),
                    ToolProperty(
                        name: "count",
                        kind: .integer,
                        summary: "How many \(axis).",
                        defaultValue: .integer(1)
                    ),
                    ToolSchema.previewProperty,
                ],
                isReadOnly: false,
                isDestructive: !inserting
            ),
            handler: { call in
                try await run(call, name: name, isRowAxis: isRowAxis, inserting: inserting)
            }
        )
    }

    private static func run(
        _ call: ToolCall,
        name: String,
        isRowAxis: Bool,
        inserting: Bool
    ) async throws -> ToolOutput {
        let path = try call.arguments.string("path")
        let preview = try call.isPreview()
        let count = try call.arguments.integer("count", default: 1)
        guard count > 0, count <= (isRowAxis ? Limits.rowCount : Limits.columnCount) else {
            throw SheetError.invalidToolArguments(tool: name, detail: "`count` must be 1 or more")
        }

        let document = try await call.broker.document(at: path)
        let resolved = try RangeSelector.sheet(
            in: document.workbook, named: call.arguments.optionalString("sheet"), tool: name
        )
        let index = try position(call, name: name, isRowAxis: isRowAxis)
        let edit = StructuralEdit(
            kind: isRowAxis
                ? (inserting ? .insertRows : .deleteRows)
                : (inserting ? .insertColumns : .deleteColumns),
            sheet: resolved.sheet.id,
            index: index,
            count: count
        )

        let outcome = try await call.broker.edit(path: path, preview: preview, tool: name) { workbook, edits in
            try StructuralEditor.apply(edit, to: &workbook, edits: &edits)
        }

        let label = isRowAxis
            ? "\(inserting ? "rows" : "rows") \(index + 1)…\(index + count)"
            : "columns \(CellRef.columnLetters(index))…\(CellRef.columnLetters(index + count - 1))"
        var lines = ["\(preview ? "would " : "")\(inserting ? "insert" : "delete") \(label) on \(resolved.sheet.name)"]
        let report = outcome.value
        if report.rewrittenFormulas > 0 {
            lines.append("adjusted \(CellText.count(report.rewrittenFormulas)) formulas")
        }
        if report.invalidatedReferences > 0 {
            lines.append("\(CellText.count(report.invalidatedReferences)) references became #REF!")
        }
        if report.unparsedFormulas > 0 {
            lines.append(
                "\(CellText.count(report.unparsedFormulas)) formulas could not be parsed and were left as written"
            )
        }
        if report.rewrittenNames > 0 { lines.append("adjusted \(report.rewrittenNames) defined names") }
        if report.brokenNames > 0 { lines.append("\(report.brokenNames) defined names lost their target") }
        lines.append(ResultFormatter.diffSummary(outcome))
        return ToolOutput(lines.joined(separator: "\n"))
    }

    /// The zero-based index, from either `at` or `column`.
    private static func position(_ call: ToolCall, name: String, isRowAxis: Bool) throws(SheetError) -> Int {
        if !isRowAxis, let letters = call.arguments.optionalString("column") {
            guard let index = CellRef.columnIndex(letters: letters.uppercased()), Limits.isValidColumn(index) else {
                throw SheetError.invalidToolArguments(tool: name, detail: "'\(letters)' is not a column letter")
            }
            return index
        }
        let value = try call.arguments.integer("at")
        guard value >= 1 else {
            throw SheetError.invalidToolArguments(tool: name, detail: "`at` is 1-based, so it must be 1 or more")
        }
        return value - 1
    }
}

/// `sort` — reorder rows within a range.
public enum SortTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "sort",
            title: "Sort a range",
            summary: """
            Sorts the rows of a range by one or more columns. Values sort in Excel's order — \
            numbers, then text, then FALSE, then TRUE, then errors, with blanks last regardless \
            of direction. A range containing formulas is **refused** unless you pass \
            `allowFormulas: true`, because sorting moves cells and a relative reference that \
            moves with them means something different afterwards; with the flag set, moved \
            formulas are translated to their new position.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range",
                    kind: .string,
                    summary: "Range to sort. Omit for the used range."
                ),
                ToolProperty(
                    name: "by",
                    kind: .array,
                    summary: "Sort keys, most significant first: "
                        + "[{column: \"B\", order: \"asc\"|\"desc\"}]. `column` is a letter.",
                    isRequired: true,
                    items: .object(["type": .string("object")])
                ),
                ToolProperty(
                    name: "hasHeader",
                    kind: .boolean,
                    summary: "Keep the first row of the range in place. Defaults to whatever "
                        + "`describe` would guess for this sheet."
                ),
                ToolProperty(
                    name: "allowFormulas",
                    kind: .boolean,
                    summary: "Sort even though the range holds formulas.",
                    defaultValue: .bool(false)
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false,
            isDestructive: true
        ),
        handler: run
    )

    private struct Key: Sendable {
        var column: Int
        var ascending: Bool
    }

    private static func run(_ call: ToolCall) async throws -> ToolOutput {
        let path = try call.arguments.string("path")
        let preview = try call.isPreview()
        let allowFormulas = try call.arguments.boolean("allowFormulas", default: false)

        let document = try await call.broker.document(at: path)
        let target = try RangeSelector.target(
            in: document.workbook,
            sheet: call.arguments.optionalString("sheet"),
            range: call.arguments.optionalString("range"),
            tool: "sort"
        )
        let sheet = document.workbook.sheets[target.sheetIndex]
        let keys = try parseKeys(call, range: target.range)

        let hasHeader: Bool = if call.arguments.has("hasHeader") {
            try call.arguments.boolean("hasHeader", default: false)
        } else {
            SheetProfiler().detectHeader(sheet, used: target.range, styles: document.workbook.styles).row
                == target.range.start.row
        }
        let firstRow = hasHeader ? target.range.start.row + 1 : target.range.start.row
        guard firstRow < target.range.end.row else {
            return ToolOutput("nothing to sort: the range has fewer than two data rows")
        }

        let styles = document.workbook.styles
        let order = ordering(sheet, rows: firstRow ... target.range.end.row, keys: keys, styles: styles)
        guard order.contains(where: { $0.from != $0.to }) else {
            return ToolOutput("already sorted; nothing written")
        }

        let columns = target.range.columns
        let sheetID = target.sheetID
        let outcome = try await call.broker.edit(path: path, preview: preview, tool: "sort") { workbook, edits in
            guard let index = workbook.index(of: sheetID) else {
                throw SheetError.sheetNotFound(reference: target.sheetName)
            }
            var moved: [(CellRef, Cell)] = []
            var formulaCount = 0
            for movement in order {
                for column in columns {
                    guard let cell = workbook.sheets[index].cells[CellRef(row: movement.from, column: column)] else {
                        continue
                    }
                    let destination = CellRef(row: movement.to, column: column)
                    var updated = cell
                    if let source = cell.formula {
                        formulaCount += 1
                        guard allowFormulas else {
                            throw SheetError.invalidToolArguments(
                                tool: "sort",
                                detail: "the range holds formulas (first at "
                                    + "\(CellRef(row: movement.from, column: column).a1String)). "
                                    + "Pass allowFormulas: true to sort anyway."
                            )
                        }
                        if let result = try? ReferenceTransform.translate(
                            formula: source,
                            from: CellRef(row: movement.from, column: column),
                            to: destination
                        ) {
                            updated.formula = result.formula
                            updated.flags.insert(.staleCache)
                        }
                    }
                    moved.append((destination, updated))
                }
            }
            workbook.sheets[index].cells.removeCells(
                in: CellRange(rows: firstRow ... target.range.end.row, columns: columns)
            )
            for (ref, cell) in moved {
                try workbook.sheets[index].cells.setCell(cell, at: ref)
            }
            edits.noteCellsChanged(in: workbook.sheets[index], formulasChanged: formulaCount > 0)
            return order.count { $0.from != $0.to }
        }

        var lines = ["\(preview ? "would move" : "moved") \(CellText.count(outcome.value)) rows in \(target.label)"]
        lines.append(ResultFormatter.diffSummary(outcome))
        return ToolOutput(lines.joined(separator: "\n"))
    }

    private struct Movement: Sendable {
        var from: Int
        var to: Int
    }

    /// Works out the permutation, without touching the sheet.
    ///
    /// A stable sort, deliberately: sorting by one column and then by another has to give the
    /// same answer as sorting by both, or an agent doing it in two calls gets a different
    /// result from an agent doing it in one.
    private static func ordering(
        _ sheet: Sheet,
        rows: ClosedRange<Int>,
        keys: [Key],
        styles: StyleTable
    ) -> [Movement] {
        let indexed = rows.enumerated().map { (position: $0.offset, row: $0.element) }
        let sorted = indexed.sorted { lhs, rhs in
            for key in keys {
                let left = sheet.cells[CellRef(row: lhs.row, column: key.column)]
                let right = sheet.cells[CellRef(row: rhs.row, column: key.column)]
                let comparison = SortOrder.compare(left, right, styles: styles)
                if comparison != .orderedSame {
                    return key.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
                }
            }
            return lhs.position < rhs.position
        }
        return sorted.enumerated().map { Movement(from: $0.element.row, to: rows.lowerBound + $0.offset) }
    }

    private static func parseKeys(_ call: ToolCall, range: CellRange) throws(SheetError) -> [Key] {
        let raw = try call.arguments.array("by")
        guard !raw.isEmpty else {
            throw SheetError.invalidToolArguments(tool: "sort", detail: "`by` must hold at least one key")
        }
        return try raw.map { entry throws(SheetError) in
            guard let members = entry.objectValue, let letters = members["column"]?.stringValue else {
                throw SheetError.invalidToolArguments(tool: "sort", detail: "each `by` entry needs a `column`")
            }
            guard let column = CellRef.columnIndex(letters: letters.uppercased()),
                  range.columns.contains(column)
            else {
                throw SheetError.invalidToolArguments(
                    tool: "sort",
                    detail: "column '\(letters)' is outside \(range.a1String(collapseSingleCell: false))"
                )
            }
            let order = members["order"]?.stringValue ?? "asc"
            guard ["asc", "desc"].contains(order) else {
                throw SheetError.invalidToolArguments(tool: "sort", detail: "`order` must be asc or desc")
            }
            return Key(column: column, ascending: order == "asc")
        }
    }
}

/// Excel's cross-type ordering.
///
/// Wave 2 addendum §15: Excel orders mixed types **number < text < FALSE < TRUE**, and A7 found
/// that LibreOffice disagrees by coercing booleans to numbers. We follow Excel, here as in the
/// formula engine, so a sort and a comparison operator cannot disagree inside one product.
///
/// Blanks sort last in **both** directions, which is Excel's own rule and is not the same as
/// "blank is the smallest value" — reversing the sort would otherwise bring every empty row to
/// the top, which is never what anyone wanted.
enum SortOrder {
    static func compare(_ lhs: Cell?, _ rhs: Cell?, styles: StyleTable) -> ComparisonResult {
        let leftBlank = lhs?.isBlank ?? true
        let rightBlank = rhs?.isBlank ?? true
        if leftBlank || rightBlank {
            if leftBlank, rightBlank { return .orderedSame }
            return leftBlank ? .orderedDescending : .orderedAscending
        }
        guard let lhs, let rhs else { return .orderedSame }
        let leftRank = rank(lhs.value)
        let rightRank = rank(rhs.value)
        if leftRank != rightRank { return leftRank < rightRank ? .orderedAscending : .orderedDescending }

        switch (lhs.value, rhs.value) {
        case let (.number(left), .number(right)):
            return left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        case let (.text(left), .text(right)):
            return left.compare(right, options: [.caseInsensitive, .numeric])
        case let (.boolean(left), .boolean(right)):
            return left == right ? .orderedSame : (right ? .orderedAscending : .orderedDescending)
        case let (.error(left), .error(right)):
            return left.rawValue.compare(right.rawValue)
        default:
            let left = CellText.plain(lhs, styles: styles)
            let right = CellText.plain(rhs, styles: styles)
            return left.compare(right)
        }
    }

    private static func rank(_ value: CellValue) -> Int {
        switch value {
        case .number: 0
        case .text: 1
        case .boolean: 2
        case .error: 3
        case .empty: 4
        }
    }
}
