import Foundation
import SheetModel

/// `read_range` — values, formulas and formats, paged.
public enum ReadRangeTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "read_range",
            title: "Read a range",
            summary: """
            Reads cells as tab-separated rows (compact, the default) or one JSON object per \
            cell (detailed: adds formula, number format, bold/fill, and the raw value). \
            Prefer `describe`, `find` or `filter` when you want to *understand* the data — \
            this tool is for when you need the actual values. Hard-capped; the result says how \
            to page. Cell text comes back inside an <untrusted-spreadsheet-content> envelope.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range",
                    kind: .string,
                    summary: "A1 range: `A1:D20`, `Sheet1!A1:D20`, `A:C` (clamped to the used "
                        + "range) or `3:7`. Omit for the whole used range.",
                ),
                ToolProperty(
                    name: "format",
                    kind: .string,
                    summary: "`compact` is TSV with an A1 row label. `detailed` is JSON per cell "
                        + "and costs roughly four times as many tokens.",
                    allowedValues: ["compact", "detailed"],
                    defaultValue: .string("compact")
                ),
                ToolProperty(
                    name: "formulas",
                    kind: .boolean,
                    summary: "In `compact`, show a formula cell as its formula instead of its value.",
                    defaultValue: .bool(false)
                ),
                ToolProperty(
                    name: "maxRows",
                    kind: .integer,
                    summary: "Rows returned before paging. The result names the next range.",
                    defaultValue: .integer(200)
                ),
                ToolProperty(
                    name: "startRow",
                    kind: .integer,
                    summary: "1-based row to resume from, for paging through a large range."
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: true
        ),
        handler: { call in
            _ = try call.isPreview()
            let path = try call.arguments.string("path")
            let format = try call.arguments.choice("format", allowed: ["compact", "detailed"], default: "compact")
            let showFormulas = try call.arguments.boolean("formulas", default: false)
            let maximumRows = try call.arguments.integer("maxRows", default: 200)
            guard maximumRows > 0 else {
                throw SheetError.invalidToolArguments(tool: "read_range", detail: "`maxRows` must be positive")
            }

            let document = try await call.broker.document(at: path)
            let target = try RangeSelector.target(
                in: document.workbook,
                sheet: call.arguments.optionalString("sheet"),
                range: call.arguments.optionalString("range"),
                tool: "read_range"
            )
            let sheet = document.workbook.sheets[target.sheetIndex]

            var range = target.range
            if call.arguments.has("startRow") {
                let start = try call.arguments.integer("startRow") - 1
                guard start >= range.start.row, start <= range.end.row else {
                    throw SheetError.invalidToolArguments(
                        tool: "read_range",
                        detail: "`startRow` must be inside \(range.a1String(collapseSingleCell: false))"
                    )
                }
                range = CellRange(rows: start ... range.end.row, columns: range.columns)
            }

            let limits = call.broker.configuration
            let rowBudget = min(maximumRows, max(1, limits.maximumCellsPerRead / max(1, range.columnCount)))
            let lastRow = min(range.end.row, range.start.row + rowBudget - 1)
            let window = CellRange(rows: range.start.row ... lastRow, columns: range.columns)
            let hasMore = lastRow < range.end.row

            let body = format == "detailed"
                ? detailed(sheet, range: window, styles: document.workbook.styles)
                : compact(sheet, range: window, styles: document.workbook.styles, formulas: showFormulas)

            var lines: [String] = []
            // Before the values, because it is about the values. See `OpenRecalculation`.
            if let notice = document.recalculationNotice { lines.append(notice) }
            lines.append("\(target.sheetName)!\(window.a1String(collapseSingleCell: false))")
            if target.wasClamped { lines[lines.count - 1] += "  (clamped to the used range)" }
            lines.append(body)
            var note: String?
            if hasMore {
                note = "truncated"
                lines.append(
                    "… \(CellText.count(range.end.row - lastRow)) more rows; "
                        + "call again with startRow=\(lastRow + 2)"
                )
            }
            return ToolOutput(UntrustedContent.wrap(
                lines.joined(separator: "\n"),
                source: document.url.path(percentEncoded: false),
                sheet: target.sheetName,
                note: note
            ))
        }
    )

    /// Tab-separated, one row per line, prefixed with the row number.
    ///
    /// The row label is what makes a compact read *addressable*: an agent that spots a bad
    /// value at line 7 of the output needs to know it is row 412 of the sheet, and counting
    /// lines is exactly the kind of arithmetic that goes wrong silently.
    static func compact(_ sheet: Sheet, range: CellRange, styles: StyleTable, formulas: Bool) -> String {
        var lines: [String] = []
        lines.append("\t" + range.columns.map { CellRef.columnLetters($0) }.joined(separator: "\t"))
        for row in range.rows {
            var fields: [String] = []
            for column in range.columns {
                guard let cell = sheet.cells[CellRef(row: row, column: column)] else {
                    fields.append("")
                    continue
                }
                if formulas, let formula = CellText.formula(cell) {
                    fields.append(UntrustedContent.inlineCell(formula))
                } else {
                    fields.append(UntrustedContent.inlineCell(CellText.plain(cell, styles: styles)))
                }
            }
            // A row of nothing but tabs is noise; the row label alone says it is blank.
            lines.append("\(row + 1)\t" + fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// One JSON object per non-empty cell.
    static func detailed(_ sheet: Sheet, range: CellRange, styles: StyleTable) -> String {
        var lines: [String] = []
        sheet.cells.forEachCell(in: range) { ref, cell in
            guard !cell.isBlank || cell.styleID != .default else { return }
            var members: [String: JSONValue] = ["ref": .string(ref.a1String)]
            switch cell.value {
            case .empty: break
            case let .number(value): members["value"] = .number(value)
            case let .text(value): members["value"] = .string(UntrustedContent.inlineCell(value, limit: 4000))
            case let .boolean(value): members["value"] = .bool(value)
            case let .error(value): members["error"] = .string(value.xlsxToken)
            }
            if let formula = CellText.formula(cell) {
                members["formula"] = .string(UntrustedContent.inlineCell(formula, limit: 4000))
            }
            let style = styles[cell.styleID]
            let format = styles.numberFormat(for: cell.styleID)
            if !format.isGeneral { members["numberFormat"] = .string(format.formatCode) }
            if style.font.isBold { members["bold"] = .bool(true) }
            if style.font.isItalic { members["italic"] = .bool(true) }
            if let fill = style.fill.effectiveColor {
                members["fill"] = .string(fill.resolved(in: styles.palette).argbHex)
            }
            if style.alignment.horizontal != .general {
                members["align"] = .string(style.alignment.horizontal.rawValue)
            }
            if !cell.flags.isEmpty, cell.flags.contains(.staleCache) { members["stale"] = .bool(true) }
            lines.append(JSONValue.object(members).rendered)
        }
        return lines.isEmpty ? "(no non-empty cells in range)" : lines.joined(separator: "\n")
    }
}

/// `find` — where something is, not what it says.
public enum FindTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "find",
            title: "Find cells",
            summary: """
            Searches values, formulas, or both, and returns **cell references, not contents** — \
            so finding 4,000 matches costs a few hundred tokens. Supports substring, whole-cell \
            and regular-expression matching. Use it to locate a column, a total row, or every \
            cell that still references a sheet you are about to delete.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false, summary: "Search only this sheet. Omit to search all."),
                ToolProperty(
                    name: "query", kind: .string, summary: "Text to look for.", isRequired: true
                ),
                ToolProperty(
                    name: "in",
                    kind: .string,
                    summary: "`values` searches displayed values, `formulas` searches formula text, "
                        + "`both` searches either.",
                    allowedValues: ["values", "formulas", "both"],
                    defaultValue: .string("values")
                ),
                ToolProperty(
                    name: "match",
                    kind: .string,
                    summary: "`contains`, `exact` (whole cell), or `regex` (ICU syntax).",
                    allowedValues: ["contains", "exact", "regex"],
                    defaultValue: .string("contains")
                ),
                ToolProperty(
                    name: "caseSensitive", kind: .boolean, summary: "Match case.", defaultValue: .bool(false)
                ),
                ToolProperty(
                    name: "range", kind: .string, summary: "Restrict the search to this A1 range."
                ),
                ToolProperty(
                    name: "limit",
                    kind: .integer,
                    summary: "Matches listed before the rest are only counted.",
                    defaultValue: .integer(200)
                ),
                ToolProperty(
                    name: "showValues",
                    kind: .boolean,
                    summary: "Include each match's text. Off by default — that is the point of this tool.",
                    defaultValue: .bool(false)
                ),
                ToolSchema.previewProperty,
            ],
            isReadOnly: true
        ),
        handler: { call in
            _ = try call.isPreview()
            let path = try call.arguments.string("path")
            let query = try call.arguments.string("query")
            let scope = try call.arguments.choice("in", allowed: ["values", "formulas", "both"], default: "values")
            let mode = try call.arguments.choice("match", allowed: ["contains", "exact", "regex"], default: "contains")
            let caseSensitive = try call.arguments.boolean("caseSensitive", default: false)
            let limit = try call.arguments.integer("limit", default: 200)
            let showValues = try call.arguments.boolean("showValues", default: false)
            guard limit > 0, limit <= 5000 else {
                throw SheetError.invalidToolArguments(tool: "find", detail: "`limit` must be 1…5000")
            }

            let document = try await call.broker.document(at: path)
            let matcher = try CellMatcher(query: query, mode: mode, caseSensitive: caseSensitive, tool: "find")
            let sheetFilter = call.arguments.optionalString("sheet")
            let rangeText = call.arguments.optionalString("range")

            var lines: [String] = []
            var total = 0
            var listed = 0
            for sheet in document.workbook.sheets {
                if let sheetFilter, sheet.name.compare(sheetFilter, options: [.caseInsensitive]) != .orderedSame {
                    continue
                }
                let bounds: CellRange
                if let rangeText {
                    bounds = try RangeSelector.parse(rangeText, used: sheet.usedRange, tool: "find").range
                } else if let used = sheet.usedRange {
                    bounds = used
                } else {
                    continue
                }
                var refs: [String] = []
                sheet.cells.forEachCell(in: bounds) { ref, cell in
                    guard matcher.matches(cell, styles: document.workbook.styles, scope: scope) else { return }
                    total += 1
                    guard listed < limit else { return }
                    listed += 1
                    if showValues {
                        let text = scope == "formulas"
                            ? (CellText.formula(cell) ?? "")
                            : CellText.plain(cell, styles: document.workbook.styles)
                        refs.append("\(ref.a1String)=\(UntrustedContent.inlineCell(text, limit: 60))")
                    } else {
                        refs.append(ref.a1String)
                    }
                }
                guard !refs.isEmpty else { continue }
                lines.append("\(sheet.name): \(refs.joined(separator: ", "))")
            }

            guard total > 0 else {
                return ToolOutput("no matches for '\(UntrustedContent.inlineCell(query, limit: 80))'")
            }
            var body = "\(CellText.count(total)) match\(total == 1 ? "" : "es")\n" + lines.joined(separator: "\n")
            if total > listed { body += "\n… \(CellText.count(total - listed)) more not listed" }
            return ToolOutput(UntrustedContent.wrap(
                body,
                source: document.url.path(percentEncoded: false),
                note: total > listed ? "truncated" : nil
            ))
        }
    )
}

/// Matching for ``FindTool`` and ``FilterTool``.
struct CellMatcher: Sendable {
    private let needle: String
    private let mode: String
    private let caseSensitive: Bool
    private let regex: NSRegularExpression?

    init(query: String, mode: String, caseSensitive: Bool, tool: String) throws(SheetError) {
        self.mode = mode
        self.caseSensitive = caseSensitive
        needle = caseSensitive ? query : query.lowercased()
        if mode == "regex" {
            do {
                regex = try NSRegularExpression(
                    pattern: query, options: caseSensitive ? [] : [.caseInsensitive]
                )
            } catch {
                throw SheetError.invalidToolArguments(
                    tool: tool, detail: "`query` is not a valid regular expression: \(error.localizedDescription)"
                )
            }
        } else {
            regex = nil
        }
    }

    func matches(_ cell: Cell, styles: StyleTable, scope: String) -> Bool {
        if scope != "formulas", matches(CellText.plain(cell, styles: styles)) { return true }
        if scope != "values", let formula = CellText.formula(cell), matches(formula) { return true }
        return false
    }

    func matches(_ text: String) -> Bool {
        guard !text.isEmpty || mode == "exact" else { return false }
        if let regex {
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let candidate = caseSensitive ? text : text.lowercased()
        return mode == "exact" ? candidate == needle : candidate.contains(needle)
    }
}
