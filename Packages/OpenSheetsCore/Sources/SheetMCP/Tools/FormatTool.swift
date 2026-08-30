import Foundation
import SheetFormat
import SheetModel

/// `set_format` — number format, weight, colour, alignment, width.
///
/// # The one thing that has to be right here
///
/// A style is interned: ``SheetModel/StyleTable/derive(_:_:)`` takes an existing style, applies
/// a change, and returns the id of the *result*, adding a new entry only if that exact
/// combination is not already in the table. So making one cell bold does not restyle every
/// other cell that happened to share its style — which is what a naive "mutate the style in
/// place" implementation does, and it is the kind of bug that silently reformats a whole
/// workbook from a one-cell edit.
///
/// The second thing is the region marking. Widths and heights live in `<cols>` and the `<row>`
/// attributes, which the writer copies through verbatim unless told otherwise (Wave 2 addendum
/// §2) — so a width change marks `.columns` and a height change marks `.rows`, and a plain
/// colour change marks neither.
public enum SetFormatTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "set_format",
            title: "Format cells",
            summary: """
            Sets number format, bold/italic/underline, font name, size and colour, fill colour, \
            alignment and wrapping over a range, column width / row height, and frozen panes \
            (freezeRows / freezeColumns, sheet-level). Only the fields you pass are changed; \
            everything else about the cells' formatting is left alone. Number formats are Excel \
            format codes, e.g. `#,##0.00`, `0.0%`, `yyyy-mm-dd`, `$#,##0;[Red]($#,##0)`.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range", kind: .string, summary: "A1 range to format.", isRequired: true
                ),
                ToolProperty(
                    name: "numberFormat", kind: .string, summary: "Excel number-format code, or `General`."
                ),
                ToolProperty(name: "bold", kind: .boolean, summary: "Bold."),
                ToolProperty(name: "italic", kind: .boolean, summary: "Italic."),
                ToolProperty(name: "underline", kind: .boolean, summary: "Single underline."),
                ToolProperty(name: "strikethrough", kind: .boolean, summary: "Strike through."),
                ToolProperty(name: "fontName", kind: .string, summary: "Font family name."),
                ToolProperty(name: "fontSize", kind: .number, summary: "Font size in points."),
                ToolProperty(
                    name: "fontColor", kind: .string, summary: "Hex `RRGGBB` or `AARRGGBB`, with or without `#`."
                ),
                ToolProperty(
                    name: "fillColor",
                    kind: .string,
                    summary: "Solid background, hex as above. `none` removes the fill."
                ),
                ToolProperty(
                    name: "align",
                    kind: .string,
                    summary: "Horizontal alignment.",
                    allowedValues: ["general", "left", "center", "right", "fill", "justify", "centerContinuous",
                                    "distributed"]
                ),
                ToolProperty(
                    name: "verticalAlign",
                    kind: .string,
                    summary: "Vertical alignment.",
                    allowedValues: ["top", "center", "bottom", "justify", "distributed"]
                ),
                ToolProperty(name: "wrap", kind: .boolean, summary: "Wrap text."),
                ToolProperty(
                    name: "columnWidth",
                    kind: .number,
                    summary: "Width in points for every column the range spans."
                ),
                ToolProperty(
                    name: "rowHeight", kind: .number, summary: "Height in points for every row the range spans."
                ),
                ToolProperty(
                    name: "freezeRows",
                    kind: .integer,
                    summary: "Freeze the top N rows of the target sheet; 0 unfreezes them. "
                        + "Sheet-level — the range only picks the sheet."
                ),
                ToolProperty(
                    name: "freezeColumns",
                    kind: .integer,
                    summary: "Freeze the left N columns of the target sheet; 0 unfreezes them. "
                        + "Sheet-level — the range only picks the sheet."
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: false
        ),
        handler: run
    )

    private static func run(_ call: ToolCall) async throws -> ToolOutput {
        let path = try call.arguments.string("path")
        let preview = try call.isPreview()
        let document = try await call.broker.document(at: path)
        let target = try RangeSelector.target(
            in: document.workbook,
            sheet: call.arguments.optionalString("sheet"),
            range: try call.arguments.string("range"),
            tool: "set_format"
        )
        let change = try StyleChange(call.arguments)
        guard !change.isEmpty else {
            throw SheetError.invalidToolArguments(
                tool: "set_format", detail: "no formatting fields were given; nothing to do"
            )
        }
        guard target.range.cellCount <= 1_000_000 else {
            throw SheetError.rangeOutOfRange(
                range: target.range.a1String,
                detail: "formatting more than a million cells at once is refused; format the columns instead"
            )
        }
        let sheetID = target.sheetID
        let range = target.range

        let outcome = try await call.broker.edit(path: path, preview: preview, tool: "set_format") { workbook, edits in
            guard let index = workbook.index(of: sheetID) else {
                throw SheetError.sheetNotFound(reference: target.sheetName)
            }
            var touched = 0
            if change.touchesCells {
                // Interned once, outside the loop: a format code becomes an id in the table,
                // and doing it per cell would add the same entry a million times.
                let formatID = change.numberFormat.map {
                    workbook.styles.internNumberFormat(NumberFormat($0))
                }
                var replacements: [(CellRef, Cell)] = []
                for ref in range {
                    let existing = workbook.sheets[index].cells[ref]
                    let base = existing?.styleID ?? workbook.sheets[index].effectiveStyleID(at: ref)
                    let derived = workbook.styles.derive(base) {
                        change.apply(to: &$0, numberFormatID: formatID)
                    }
                    guard derived != base else { continue }
                    // A style on an empty cell is a real thing — a formatted column waiting for
                    // data — so it is written rather than skipped.
                    var cell = existing ?? Cell()
                    cell.styleID = derived
                    replacements.append((ref, cell))
                }
                for (ref, cell) in replacements {
                    try workbook.sheets[index].cells.setCell(cell, at: ref)
                }
                touched = replacements.count
            }

            var regions: SheetRegionChanges = change.touchesCells ? [.cells] : []
            if let width = change.columnWidth {
                workbook.sheets[index].columnWidths.setValue(width, in: range.columns)
                regions.insert(.columns)
            }
            if let height = change.rowHeight {
                workbook.sheets[index].rowHeights.setValue(height, in: range.rows)
                regions.insert(.rows)
            }
            // Panes live in `<sheetViews>`, which the writer copies through verbatim unless
            // `.views` is marked — without it the freeze would hold in memory and vanish from
            // the file, which is the worst kind of success.
            if let rows = change.freezeRows {
                workbook.sheets[index].frozen.frozenRows = rows
                regions.insert(.views)
            }
            if let columns = change.freezeColumns {
                workbook.sheets[index].frozen.frozenColumns = columns
                regions.insert(.views)
            }
            edits.note(workbook.sheets[index], regions)
            if change.touchesCells { edits.noteStylesChanged() }
            return touched
        }

        var lines = ["\(preview ? "would format" : "formatted") \(CellText.count(outcome.value)) cells in "
            + "\(target.sheetName)!\(range.a1String(collapseSingleCell: false))"]
        if change.columnWidth != nil { lines.append("column width set for \(range.columnCount) columns") }
        if change.rowHeight != nil { lines.append("row height set for \(CellText.count(range.rowCount)) rows") }
        if let rows = change.freezeRows {
            lines.append(rows == 0
                ? "unfroze rows on \(target.sheetName)"
                : "froze the top \(rows) row\(rows == 1 ? "" : "s") of \(target.sheetName)")
        }
        if let columns = change.freezeColumns {
            lines.append(columns == 0
                ? "unfroze columns on \(target.sheetName)"
                : "froze the left \(columns) column\(columns == 1 ? "" : "s") of \(target.sheetName)")
        }
        lines.append(ResultFormatter.diffSummary(outcome))
        return ToolOutput(lines.joined(separator: "\n"))
    }
}

/// The formatting fields that were actually supplied.
///
/// Optionals throughout, because "not given" and "given as false" are different instructions
/// and collapsing them would make `set_format` un-bold everything it touched.
struct StyleChange: Sendable {
    var numberFormat: String?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strikethrough: Bool?
    var fontName: String?
    var fontSize: Double?
    var fontColor: StyleColor?
    var fillColor: StyleColor??
    var align: CellAlignment.Horizontal?
    var verticalAlign: CellAlignment.Vertical?
    var wrap: Bool?
    var columnWidth: Double?
    var rowHeight: Double?
    var freezeRows: Int?
    var freezeColumns: Int?

    init(_ arguments: ToolArguments) throws(SheetError) {
        numberFormat = arguments.optionalString("numberFormat")
        if let code = numberFormat { _ = try NumberFormat.validated(code) }
        bold = arguments.has("bold") ? try arguments.boolean("bold", default: false) : nil
        italic = arguments.has("italic") ? try arguments.boolean("italic", default: false) : nil
        underline = arguments.has("underline") ? try arguments.boolean("underline", default: false) : nil
        strikethrough = arguments.has("strikethrough")
            ? try arguments.boolean("strikethrough", default: false)
            : nil
        wrap = arguments.has("wrap") ? try arguments.boolean("wrap", default: false) : nil
        fontName = arguments.optionalString("fontName")

        if arguments.has("fontSize") {
            let size = arguments.values["fontSize"]?.doubleValue ?? 0
            guard size >= 1, size <= 409 else {
                throw SheetError.invalidToolArguments(tool: arguments.tool, detail: "`fontSize` must be 1…409")
            }
            fontSize = size
        }
        if let text = arguments.optionalString("fontColor") {
            fontColor = .rgb(try StyleChange.colour(text, field: "fontColor", tool: arguments.tool))
        }
        if let text = arguments.optionalString("fillColor") {
            fillColor = text.lowercased() == "none"
                ? .some(nil)
                : .some(.rgb(try StyleChange.colour(text, field: "fillColor", tool: arguments.tool)))
        }
        if let text = arguments.optionalString("align") {
            guard let value = CellAlignment.Horizontal(rawValue: text) else {
                throw SheetError.invalidToolArguments(tool: arguments.tool, detail: "unknown `align` '\(text)'")
            }
            align = value
        }
        if let text = arguments.optionalString("verticalAlign") {
            guard let value = CellAlignment.Vertical(rawValue: text) else {
                throw SheetError.invalidToolArguments(
                    tool: arguments.tool, detail: "unknown `verticalAlign` '\(text)'"
                )
            }
            verticalAlign = value
        }
        if arguments.has("columnWidth") {
            let width = arguments.values["columnWidth"]?.doubleValue ?? 0
            guard width >= 0, width <= 4000 else {
                throw SheetError.invalidToolArguments(tool: arguments.tool, detail: "`columnWidth` must be 0…4000")
            }
            columnWidth = width
        }
        if arguments.has("rowHeight") {
            let height = arguments.values["rowHeight"]?.doubleValue ?? 0
            guard height >= 0, height <= 2000 else {
                throw SheetError.invalidToolArguments(tool: arguments.tool, detail: "`rowHeight` must be 0…2000")
            }
            rowHeight = height
        }
        // Through the bounded accessor, like every count-shaped argument: a negative or
        // absurd freeze must be a `tool.invalidArguments`, never something the model traps
        // on later. `0` is inside the range on purpose — it is the documented spelling of
        // "unfreeze".
        if arguments.has("freezeRows") {
            freezeRows = try arguments.integer("freezeRows", default: 0, atLeast: 0, atMost: Limits.rowCount)
        }
        if arguments.has("freezeColumns") {
            freezeColumns = try arguments.integer(
                "freezeColumns", default: 0, atLeast: 0, atMost: Limits.columnCount
            )
        }
    }

    var touchesCells: Bool {
        numberFormat != nil || bold != nil || italic != nil || underline != nil || strikethrough != nil
            || fontName != nil || fontSize != nil || fontColor != nil || fillColor != nil
            || align != nil || verticalAlign != nil || wrap != nil
    }

    var isEmpty: Bool {
        !touchesCells && columnWidth == nil && rowHeight == nil
            && freezeRows == nil && freezeColumns == nil
    }

    /// Applies the supplied fields to a style. Called inside `StyleTable.derive`, which is what
    /// makes the result interned rather than a mutation of a shared style.
    ///
    /// - Parameter numberFormatID: the id ``numberFormat`` was interned to, resolved by the
    ///   caller because interning needs the table and `derive` does not hand it over.
    func apply(to style: inout CellStyle, numberFormatID: Int32?) {
        if let numberFormatID { style.numberFormatID = numberFormatID }
        if let bold { style.font.isBold = bold }
        if let italic { style.font.isItalic = italic }
        if let underline { style.font.underline = underline ? .single : .none }
        if let strikethrough { style.font.isStrikethrough = strikethrough }
        if let fontName { style.font.name = fontName }
        if let fontSize { style.font.size = fontSize }
        if let fontColor { style.font.color = fontColor }
        if let fillColor {
            style.fill = fillColor.map { FillStyle.solid($0) } ?? .none
        }
        if let align { style.alignment.horizontal = align }
        if let verticalAlign { style.alignment.vertical = verticalAlign }
        if let wrap { style.alignment.wrapText = wrap }
    }

    private static func colour(_ text: String, field: String, tool: String) throws(SheetError) -> RGBAColor {
        var hex = text.hasPrefix("#") ? String(text.dropFirst()) : text
        if hex.count == 6 { hex = "FF" + hex }
        guard hex.count == 8, let colour = RGBAColor(argbHex: hex) else {
            throw SheetError.invalidToolArguments(
                tool: tool, detail: "`\(field)` must be hex RRGGBB or AARRGGBB, got '\(text)'"
            )
        }
        return colour
    }
}
