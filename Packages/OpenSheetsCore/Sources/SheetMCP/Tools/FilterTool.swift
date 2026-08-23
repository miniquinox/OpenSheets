import Foundation
import SheetModel

/// One `where` clause.
struct FilterCondition: Sendable {
    enum Comparison: String, Sendable, CaseIterable {
        case equals = "eq"
        case notEquals = "ne"
        case lessThan = "lt"
        case lessOrEqual = "lte"
        case greaterThan = "gt"
        case greaterOrEqual = "gte"
        case contains
        case startsWith
        case endsWith
        case matches
        case isEmpty
        case notEmpty
        case isError
    }

    var column: Int
    var comparison: Comparison
    var text: String?
    var number: Double?
    var regex: NSRegularExpression?

    /// Evaluates against one cell.
    ///
    /// Numeric comparisons only fire when **both** sides are numbers. A `<` between a number
    /// and the text `"n/a"` is not false, it is meaningless, and Excel's answer to it (text
    /// sorts above every number) is a trap for anyone filtering for "everything below zero".
    /// So a type mismatch simply does not match, and the result says how many cells were
    /// skipped for that reason.
    func evaluate(_ cell: Cell?, styles: StyleTable) -> FilterOutcome {
        let text = cell.map { CellText.plain($0, styles: styles) } ?? ""
        switch comparison {
        case .isEmpty:
            return (cell?.isBlank ?? true) ? .match : .noMatch
        case .notEmpty:
            return (cell?.isBlank ?? true) ? .noMatch : .match
        case .isError:
            return (cell?.value.isError ?? false) ? .match : .noMatch
        case .contains, .startsWith, .endsWith:
            guard let needle = self.text else { return .noMatch }
            let haystack = text.lowercased()
            let lowered = needle.lowercased()
            switch comparison {
            case .contains: return haystack.contains(lowered) ? .match : .noMatch
            case .startsWith: return haystack.hasPrefix(lowered) ? .match : .noMatch
            default: return haystack.hasSuffix(lowered) ? .match : .noMatch
            }
        case .matches:
            guard let regex else { return .noMatch }
            let range = NSRange(text.startIndex..., in: text)
            return regex.firstMatch(in: text, range: range) != nil ? .match : .noMatch
        case .equals, .notEquals:
            let same = compareEquality(cell, text: text)
            return (comparison == .equals) == same ? .match : .noMatch
        case .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
            guard let threshold = number else {
                guard let needle = self.text else { return .noMatch }
                return ordered(text.compare(needle)) ? .match : .noMatch
            }
            guard let value = cell?.value.number else { return .skipped }
            return ordered(value < threshold ? .orderedAscending
                : (value > threshold ? .orderedDescending : .orderedSame)) ? .match : .noMatch
        }
    }

    private func compareEquality(_ cell: Cell?, text: String) -> Bool {
        if let number, let value = cell?.value.number { return value == number }
        guard let needle = self.text else { return cell?.isBlank ?? true }
        return text.compare(needle, options: [.caseInsensitive]) == .orderedSame
    }

    private func ordered(_ result: ComparisonResult) -> Bool {
        switch comparison {
        case .lessThan: result == .orderedAscending
        case .lessOrEqual: result != .orderedDescending
        case .greaterThan: result == .orderedDescending
        case .greaterOrEqual: result != .orderedAscending
        default: false
        }
    }
}

/// Whether a condition matched, missed, or could not be applied.
enum FilterOutcome: Sendable {
    case match
    case noMatch
    /// The comparison did not apply to this cell's type — see ``FilterCondition/evaluate(_:styles:)``.
    case skipped
}

/// `filter` — "every row where …", answered as row numbers rather than data.
///
/// This is the tool that turns *"find every row where margin < 0"* from a 50,000-row read into
/// a twenty-token answer, and `action: "delete_rows"` turns the follow-up from 400 tool calls
/// into one.
public enum FilterTool {
    public static let definition = ToolDefinition(
        schema: ToolSchema(
            name: "filter",
            title: "Filter rows",
            summary: """
            Finds rows matching one or more conditions and returns their row numbers — \
            optionally with a few named columns. With `action: "delete_rows"` it deletes every \
            matching row in one pass (formulas are adjusted, and a snapshot is taken first). \
            Always run it with `preview: true` before deleting. Conditions on a column are \
            ANDed; a comparison that does not apply to a cell's type is counted and reported \
            rather than silently treated as false.
            """,
            properties: [
                ToolSchema.pathProperty,
                ToolSchema.sheetProperty(required: false),
                ToolProperty(
                    name: "range",
                    kind: .string,
                    summary: "A1 range to filter. Omit for the used range."
                ),
                ToolProperty(
                    name: "headerRow",
                    kind: .integer,
                    summary: "1-based header row, so conditions can name columns by header text. "
                        + "Omit to use the row `describe` guessed."
                ),
                ToolProperty(
                    name: "where",
                    kind: .array,
                    summary: "Conditions, ANDed. Each is "
                        + "{column: \"B\" or a header name, op: eq|ne|lt|lte|gt|gte|contains|"
                        + "startsWith|endsWith|matches|isEmpty|notEmpty|isError, value: …}.",
                    isRequired: true,
                    items: .object(["type": .string("object")])
                ),
                ToolProperty(
                    name: "columns",
                    kind: .array,
                    summary: "Column letters or header names to show for each matching row. "
                        + "Omit to return row numbers only.",
                    items: .object(["type": .string("string")])
                ),
                ToolProperty(
                    name: "action",
                    kind: .string,
                    summary: "`list` reports the matches. `delete_rows` removes them.",
                    allowedValues: ["list", "delete_rows"],
                    defaultValue: .string("list")
                ),
                ToolProperty(
                    name: "limit",
                    kind: .integer,
                    summary: "Rows listed before the rest are only counted.",
                    defaultValue: .integer(100)
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
        let action = try call.arguments.choice("action", allowed: ["list", "delete_rows"], default: "list")
        let limit = try call.arguments.integer("limit", default: 100)

        let document = try await call.broker.document(at: path)
        let target = try RangeSelector.target(
            in: document.workbook,
            sheet: call.arguments.optionalString("sheet"),
            range: call.arguments.optionalString("range"),
            tool: "filter"
        )
        let sheet = document.workbook.sheets[target.sheetIndex]
        let styles = document.workbook.styles

        let headerRow = try resolveHeaderRow(call, sheet: sheet, target: target, styles: styles)
        let headerMap = headerRow.map { columnsByHeader(sheet, row: $0, range: target.range, styles: styles) } ?? [:]
        let conditions = try parseConditions(call, headers: headerMap, range: target.range)
        let shown = try (call.arguments.optionalArray("columns") ?? []).map { value -> Int in
            guard let text = value.stringValue else {
                throw SheetError.invalidToolArguments(tool: "filter", detail: "`columns` holds a non-string")
            }
            return try resolveColumn(text, headers: headerMap, range: target.range)
        }

        let firstBody = headerRow.map { $0 + 1 } ?? target.range.start.row
        var matches: [Int] = []
        var skipped = 0
        guard firstBody <= target.range.end.row else {
            return ToolOutput("0 rows matched (the range holds only a header)")
        }
        for row in firstBody ... target.range.end.row {
            var matched = true
            for condition in conditions {
                switch condition.evaluate(sheet.cells[CellRef(row: row, column: condition.column)], styles: styles) {
                case .match: continue
                case .noMatch: matched = false
                case .skipped:
                    matched = false
                    skipped += 1
                }
                if !matched { break }
            }
            if matched { matches.append(row) }
        }

        if action == "list" {
            return listing(
                matches, skipped: skipped, limit: limit, sheet: sheet, target: target,
                columns: shown, styles: styles, source: document.url.path(percentEncoded: false)
            )
        }
        return try await delete(matches, call: call, path: path, target: target, preview: preview, skipped: skipped)
    }

    // MARK: - Listing

    private static func listing(
        _ matches: [Int],
        skipped: Int,
        limit: Int,
        sheet: Sheet,
        target: RangeTarget,
        columns: [Int],
        styles: StyleTable,
        source: String
    ) -> ToolOutput {
        guard !matches.isEmpty else {
            let note = skipped > 0 ? " (\(CellText.count(skipped)) cells skipped: wrong type for the comparison)" : ""
            return ToolOutput("0 rows matched\(note)")
        }
        var lines = ["\(CellText.count(matches.count)) rows matched in \(target.label)"]
        if skipped > 0 {
            lines.append("\(CellText.count(skipped)) cells skipped: the comparison did not apply to their type")
        }
        if columns.isEmpty {
            lines.append("rows: " + matches.prefix(limit).map { String($0 + 1) }.joined(separator: ", "))
        } else {
            lines.append("row\t" + columns.map { CellRef.columnLetters($0) }.joined(separator: "\t"))
            for row in matches.prefix(limit) {
                let fields = columns.map { column -> String in
                    guard let cell = sheet.cells[CellRef(row: row, column: column)] else { return "" }
                    return UntrustedContent.inlineCell(CellText.plain(cell, styles: styles), limit: 60)
                }
                lines.append("\(row + 1)\t" + fields.joined(separator: "\t"))
            }
        }
        if matches.count > limit {
            lines.append("… \(CellText.count(matches.count - limit)) more not listed")
        }
        return ToolOutput(UntrustedContent.wrap(
            lines.joined(separator: "\n"), source: source, sheet: target.sheetName,
            note: matches.count > limit ? "truncated" : nil
        ))
    }

    // MARK: - Deleting

    private static func delete(
        _ matches: [Int],
        call: ToolCall,
        path: String,
        target: RangeTarget,
        preview: Bool,
        skipped: Int
    ) async throws -> ToolOutput {
        guard !matches.isEmpty else { return ToolOutput("0 rows matched; nothing deleted") }
        // Bottom-up, so each delete cannot move a row that is still on the list. The bands are
        // coalesced first so 400 contiguous rows are one structural edit rather than 400 —
        // which matters because every one of them rewrites every formula in the workbook.
        let bands = StructuralEditor.bands(rows: matches).reversed()
        let sheetID = target.sheetID
        let outcome = try await call.broker.edit(path: path, preview: preview, tool: "filter") { workbook, edits in
            for band in bands {
                try StructuralEditor.apply(
                    .deleteRows(at: band.start, count: band.count, on: sheetID),
                    to: &workbook, edits: &edits
                )
            }
            return matches.count
        }
        var lines = ["\(preview ? "would delete" : "deleted") \(CellText.count(outcome.value)) rows in "
            + "\(target.sheetName) (\(bands.count) contiguous block\(bands.count == 1 ? "" : "s"))"]
        if skipped > 0 {
            lines.append("\(CellText.count(skipped)) cells were skipped: wrong type for the comparison")
        }
        lines.append(ResultFormatter.diffSummary(outcome))
        return ToolOutput(lines.joined(separator: "\n"))
    }

    // MARK: - Argument plumbing

    private static func resolveHeaderRow(
        _ call: ToolCall,
        sheet: Sheet,
        target: RangeTarget,
        styles: StyleTable
    ) throws(SheetError) -> Int? {
        if call.arguments.has("headerRow") {
            let row = try call.arguments.integer("headerRow") - 1
            guard row >= 0, Limits.isValidRow(row) else {
                throw SheetError.invalidToolArguments(tool: "filter", detail: "`headerRow` must be 1 or more")
            }
            return row
        }
        return SheetProfiler().detectHeader(sheet, used: target.range, styles: styles).row
    }

    private static func columnsByHeader(
        _ sheet: Sheet,
        row: Int,
        range: CellRange,
        styles: StyleTable
    ) -> [String: Int] {
        var map: [String: Int] = [:]
        for column in range.columns {
            guard let cell = sheet.cells[CellRef(row: row, column: column)], !cell.isBlank else { continue }
            let label = CellText.plain(cell, styles: styles).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            // First wins: two columns headed `Total` is real, and silently filtering on the
            // second one would be the wrong guess.
            if map[label.lowercased()] == nil { map[label.lowercased()] = column }
        }
        return map
    }

    private static func resolveColumn(
        _ text: String,
        headers: [String: Int],
        range: CellRange
    ) throws(SheetError) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let column = headers[trimmed.lowercased()] { return column }
        if trimmed.allSatisfy(\.isLetter), let column = CellRef.columnIndex(letters: trimmed.uppercased()),
           range.columns.contains(column) {
            return column
        }
        let known = headers.keys.sorted().prefix(20).joined(separator: ", ")
        throw SheetError.invalidToolArguments(
            tool: "filter",
            detail: "'\(text)' is neither a column letter in \(range.a1String(collapseSingleCell: false)) "
                + "nor a header in this sheet\(known.isEmpty ? "" : ". Headers: \(known)")"
        )
    }

    private static func parseConditions(
        _ call: ToolCall,
        headers: [String: Int],
        range: CellRange
    ) throws(SheetError) -> [FilterCondition] {
        let raw = try call.arguments.array("where")
        guard !raw.isEmpty else {
            throw SheetError.invalidToolArguments(tool: "filter", detail: "`where` must hold at least one condition")
        }
        var conditions: [FilterCondition] = []
        for entry in raw {
            guard let members = entry.objectValue else {
                throw SheetError.invalidToolArguments(tool: "filter", detail: "each `where` entry must be an object")
            }
            guard let columnText = members["column"]?.stringValue else {
                throw SheetError.invalidToolArguments(tool: "filter", detail: "a `where` entry has no `column`")
            }
            guard let operation = members["op"]?.stringValue,
                  let comparison = FilterCondition.Comparison(rawValue: operation)
            else {
                let allowed = FilterCondition.Comparison.allCases.map(\.rawValue).joined(separator: ", ")
                throw SheetError.invalidToolArguments(
                    tool: "filter", detail: "`op` must be one of \(allowed)"
                )
            }
            var condition = FilterCondition(
                column: try resolveColumn(columnText, headers: headers, range: range),
                comparison: comparison
            )
            switch members["value"] {
            case let .string(text):
                condition.text = text
                if comparison == .matches {
                    condition.regex = try CellMatcher.compile(text, tool: "filter")
                }
            case let .integer(value): condition.number = Double(value)
            case let .number(value): condition.number = value
            case let .bool(value): condition.text = value ? "TRUE" : "FALSE"
            default:
                guard [.isEmpty, .notEmpty, .isError].contains(comparison) else {
                    throw SheetError.invalidToolArguments(
                        tool: "filter", detail: "`\(operation)` needs a `value`"
                    )
                }
            }
            conditions.append(condition)
        }
        return conditions
    }
}

extension CellMatcher {
    /// Compiles a pattern, reporting a bad one as a tool-argument failure rather than throwing
    /// something an MCP client cannot classify.
    static func compile(_ pattern: String, tool: String) throws(SheetError) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw SheetError.invalidToolArguments(
                tool: tool, detail: "not a valid regular expression: \(error.localizedDescription)"
            )
        }
    }
}
