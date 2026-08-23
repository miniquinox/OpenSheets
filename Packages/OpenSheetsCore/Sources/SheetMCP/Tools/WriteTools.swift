import Foundation
import SheetFormat
import SheetFormula
import SheetModel

/// `write_range` — put values or formulas into a rectangle.
public enum WriteRangeTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "write_range",
            title: "Write a range",
            summary: """
            Writes a rectangle of values or formulas and reports exactly what changed. Give \
            `values` as an array of rows; a string beginning with `=` is stored as a formula \
            and is validated before anything is written — an unparseable formula fails the \
            whole call rather than landing half-applied. One call per rectangle is much \
            cheaper than one call per cell. Run with `preview: true` first when overwriting \
            existing data.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range",
                    kind: .string,
                    summary: "Top-left cell (`B2`) or the full rectangle (`B2:D10`). "
                        + "If a rectangle is given, `values` must match its shape.",
                    isRequired: true
                ),
                ToolProperty(
                    name: "values",
                    kind: .array,
                    summary: "Rows of cells: [[1, 2], [\"text\", \"=A1*2\"]]. "
                        + "`null` clears a cell. A string starting with `=` becomes a formula; "
                        + "prefix with `'` to write a literal that begins with `=`.",
                    isRequired: true,
                    items: .object(["type": .string("array")])
                ),
                ToolProperty(
                    name: "recalculate",
                    kind: .boolean,
                    summary: "Recompute dependent formulas after the write and report the cells "
                        + "whose values changed.",
                    defaultValue: .bool(true)
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false,
            isDestructive: true
        ),
        handler: run
    )

    private static func run(_ call: ToolCall) async throws -> ToolOutput {
        let path = try call.arguments.string("path")
        let preview = try call.isPreview()
        let recalculate = try call.arguments.boolean("recalculate", default: true)
        let rows = try call.arguments.array("values")
        guard !rows.isEmpty else {
            throw SheetError.invalidToolArguments(tool: "write_range", detail: "`values` is empty")
        }

        let document = try await call.broker.document(at: path)
        let target = try RangeSelector.target(
            in: document.workbook,
            sheet: call.arguments.optionalString("sheet"),
            range: try call.arguments.string("range"),
            tool: "write_range"
        )
        let block = try CellBlock(rows: rows, tool: "write_range")
        let destination = try block.destination(anchoredAt: target.range, tool: "write_range")
        let sheetID = target.sheetID

        let outcome = try await call.broker.edit(path: path, preview: preview, tool: "write_range") { workbook, edits in
            guard let index = workbook.index(of: sheetID) else {
                throw SheetError.sheetNotFound(reference: target.sheetName)
            }
            var engine = FormulaEngine(workbook: workbook)
            var changed: Set<SheetCell> = []
            var formulasChanged = false

            // Every cell is written into a *copy* of the workbook, which `DocumentBroker.edit`
            // discards if this closure throws. That is what makes "an unparseable formula writes
            // nothing" true rather than aspirational: there is no partial state to roll back,
            // because nothing reached the file in the first place.
            for entry in block.entries {
                let ref = CellRef(
                    row: destination.start.row + entry.row,
                    column: destination.start.column + entry.column
                )
                try ref.validated()
                let existing = workbook.sheets[index].cells[ref]
                var cell = existing ?? Cell()
                if existing?.formula != nil { formulasChanged = true }
                cell.formula = nil

                switch entry.value {
                case .blank:
                    workbook.sheets[index].cells.removeCell(at: ref)
                    changed.insert(SheetCell(sheet: sheetID, ref: ref))
                    engine.setFormula(nil, at: SheetCell(sheet: sheetID, ref: ref), in: workbook)
                    continue
                case let .literal(value):
                    cell.value = value
                case let .formula(source):
                    guard engine.setFormula(source, at: SheetCell(sheet: sheetID, ref: ref), in: workbook) else {
                        throw SheetError.invalidFormula(
                            text: "=" + source,
                            position: nil,
                            reason: "it does not parse, so the whole call was refused and nothing was written"
                        )
                    }
                    cell.formula = source
                    cell.value = .empty
                    cell.flags.insert(.staleCache)
                    formulasChanged = true
                }
                try workbook.sheets[index].cells.setCell(cell, at: ref)
                changed.insert(SheetCell(sheet: sheetID, ref: ref))
            }

            var recalculated = 0
            var stale = 0
            if recalculate {
                let result = engine.recalculate(in: workbook, changed: changed, includingVolatile: true)
                result.apply(to: &workbook)
                recalculated = result.values.count
                stale = result.stale.count
            }
            edits.noteCellsChanged(in: workbook.sheets[index], formulasChanged: formulasChanged)
            return WriteReport(written: block.entries.count, recalculated: recalculated, stale: stale)
        }

        var lines = [
            "\(preview ? "would write" : "wrote") \(CellText.count(outcome.value.written)) cells to "
                + "\(target.sheetName)!\(destination.a1String(collapseSingleCell: false))",
        ]
        if outcome.value.recalculated > 0 {
            lines.append("recalculated \(CellText.count(outcome.value.recalculated)) dependent cells")
        }
        if outcome.value.stale > 0 {
            lines.append(
                "\(CellText.count(outcome.value.stale)) formulas kept their cached value "
                    + "(unsupported function); Excel will recompute them on open"
            )
        }
        lines.append(ResultFormatter.diffSummary(outcome))
        if preview, let detail = ResultFormatter.changeDetail(outcome.diff, styles: document.workbook.styles) {
            lines.append(detail)
        }
        return ToolOutput(lines.joined(separator: "\n"))
    }

    struct WriteReport: Sendable {
        var written: Int
        var recalculated: Int
        var stale: Int
    }
}

/// A rectangle of incoming values, validated before anything is written.
struct CellBlock: Sendable {
    enum Incoming: Sendable {
        case blank
        case literal(CellValue)
        case formula(String)
    }

    struct Entry: Sendable {
        var row: Int
        var column: Int
        var value: Incoming
    }

    var rowCount: Int
    var columnCount: Int
    var entries: [Entry]

    /// Parses the `values` argument.
    ///
    /// Ragged input is accepted — a row shorter than the widest one leaves the rest of that
    /// row alone rather than clearing it. That is what an agent means by sending three values
    /// for a four-column row, and clearing the fourth would be a destructive interpretation of
    /// an omission.
    init(rows: [JSONValue], tool: String) throws(SheetError) {
        var entries: [Entry] = []
        var widest = 0
        for (rowIndex, row) in rows.enumerated() {
            guard let cells = row.arrayValue else {
                throw SheetError.invalidToolArguments(
                    tool: tool, detail: "`values`[\(rowIndex)] is not an array of cells"
                )
            }
            widest = max(widest, cells.count)
            for (columnIndex, value) in cells.enumerated() {
                entries.append(Entry(
                    row: rowIndex, column: columnIndex, value: try CellBlock.read(value, tool: tool)
                ))
            }
        }
        guard !entries.isEmpty else {
            throw SheetError.invalidToolArguments(tool: tool, detail: "`values` holds no cells")
        }
        rowCount = rows.count
        columnCount = widest
        self.entries = entries
    }

    /// Where the block lands, checking the shape when the caller named a rectangle.
    func destination(anchoredAt range: CellRange, tool: String) throws(SheetError) -> CellRange {
        let target = CellRange(
            rows: range.start.row ... (range.start.row + rowCount - 1),
            columns: range.start.column ... (range.start.column + columnCount - 1)
        )
        guard !range.isSingleCell else {
            guard target.isValid else {
                throw SheetError.rangeOutOfRange(
                    range: target.a1String, detail: "the block does not fit on the sheet"
                )
            }
            return target
        }
        guard range.rowCount == rowCount, range.columnCount == columnCount else {
            throw SheetError.rangeShapeMismatch(
                expectedRows: range.rowCount,
                expectedColumns: range.columnCount,
                actualRows: rowCount,
                actualColumns: columnCount
            )
        }
        return range
    }

    private static func read(_ value: JSONValue, tool: String) throws(SheetError) -> Incoming {
        switch value {
        case .null:
            return .blank
        case let .bool(flag):
            return .literal(.boolean(flag))
        case let .integer(number):
            return .literal(.number(Double(number)))
        case let .number(number):
            return .literal(.number(number))
        case let .string(text):
            return try readString(text, tool: tool)
        case .array, .object:
            throw SheetError.invalidToolArguments(
                tool: tool, detail: "a cell must be a string, number, boolean, or null"
            )
        }
    }

    private static func readString(_ text: String, tool _: String) throws(SheetError) -> Incoming {
        if text.hasPrefix("=") {
            let source = String(text.dropFirst())
            guard !source.isEmpty else {
                throw SheetError.invalidFormula(text: text, position: 0, reason: "the formula is empty")
            }
            guard source.utf8.count <= Limits.maxFormulaLength else {
                throw SheetError.formulaTooLong(length: source.utf8.count, limit: Limits.maxFormulaLength)
            }
            return .formula(source)
        }
        // An apostrophe is Excel's own escape for "this text really does start with =". Keeping
        // it means an agent can round-trip a cell whose literal content is `=SUM(A1)` without
        // the server deciding it meant a formula.
        if text.hasPrefix("'") {
            return .literal(.text(String(text.dropFirst())))
        }
        if let token = CellError.allCases.first(where: { $0.isExcelNative && $0.rawValue == text }) {
            return .literal(.error(token))
        }
        guard text.count <= Limits.maxCellTextLength else {
            throw SheetError.cellTextTooLong(ref: "", length: text.count, limit: Limits.maxCellTextLength)
        }
        return .literal(.text(text))
    }
}

/// `recalc` — recompute everything and say what moved.
public enum RecalcTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "recalc",
            title: "Recalculate",
            summary: """
            Recomputes every formula in the workbook and reports the cells whose values \
            changed. Use it after editing inputs that another tool wrote without recalculating, \
            or to find out which cached values a file disagrees with. Formulas using functions \
            OpenSheets does not implement keep their cached value and are listed separately — \
            they are never replaced with a guess.
            """,
            properties: [ToolSchema.pathProperty, ToolSchema.previewProperty],
            isReadOnly: false
        ),
        handler: { call in
            let path = try call.arguments.string("path")
            let preview = try call.isPreview()
            let outcome = try await call.broker.edit(path: path, preview: preview, tool: "recalc") { workbook, edits in
                let engine = FormulaEngine(workbook: workbook)
                let result = engine.recalculateAll(in: workbook)
                result.apply(to: &workbook)
                for sheet in workbook.sheets {
                    // Values changed, formulas did not: `formulasChanged: false` keeps the
                    // calculation chain, which still describes this workbook correctly.
                    edits.noteCellsChanged(in: sheet, formulasChanged: false)
                }
                return RecalcReport(
                    evaluated: result.evaluatedCount,
                    stale: result.stale.count,
                    circular: result.circular.count,
                    staleReasons: Set(result.stale.values.map { "\($0)" }).sorted().prefix(5).joined(separator: ", ")
                )
            }
            var lines = [
                "evaluated \(CellText.count(outcome.value.evaluated)) formulas",
            ]
            if outcome.value.stale > 0 {
                lines.append(
                    "\(CellText.count(outcome.value.stale)) kept their cached value: \(outcome.value.staleReasons)"
                )
            }
            if outcome.value.circular > 0 {
                lines.append("\(CellText.count(outcome.value.circular)) cells are in a circular reference")
            }
            lines.append(ResultFormatter.diffSummary(outcome))
            return ToolOutput(lines.joined(separator: "\n"))
        }
    )

    struct RecalcReport: Sendable {
        var evaluated: Int
        var stale: Int
        var circular: Int
        var staleReasons: String
    }
}
