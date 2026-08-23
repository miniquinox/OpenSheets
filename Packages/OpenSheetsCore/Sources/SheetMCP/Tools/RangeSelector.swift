import Foundation
import SheetModel

/// A resolved sheet-and-rectangle, which is what most tools actually operate on.
public struct RangeTarget: Sendable, Hashable {
    public var sheetIndex: Int
    public var sheetID: SheetID
    /// Untrusted content — it came from the file.
    public var sheetName: String
    public var range: CellRange
    /// Whether the caller wrote `A:C` or `3:7` and this rectangle is the used-range clamp of
    /// it. Reported so a result can say *"A:C, clamped to A1:C4021"* rather than quietly
    /// answering a different question.
    public var wasClamped: Bool

    /// `Sheet1!A1:C20`, quoted if the name needs it.
    public var label: String {
        A1Notation.format(sheetName: sheetName, range: range, collapseSingleCell: false)
    }
}

/// Turns `sheet` and `range` arguments into something a tool can use.
///
/// Accepts every spelling an agent is likely to produce, because the alternative is an agent
/// spending a round trip discovering that this server wanted `Sheet1!A1:D20` and not
/// `'Sheet1'!A1:D20`:
///
/// | Written | Means |
/// | --- | --- |
/// | `A1:D20` | that rectangle on the `sheet` argument, or the first visible sheet |
/// | `Sales!A1:D20` | that rectangle on `Sales`, and `sheet` must agree if it is also given |
/// | `'Q3 2026'!A1` | one cell on a sheet whose name needs quoting |
/// | `A:C` | those columns, **clamped to the used range** |
/// | `3:7` | those rows, clamped the same way |
/// | absent | the whole used range |
///
/// Whole-column and whole-row references are clamped rather than taken literally because
/// `A:A` is 1,048,576 cells and an agent that wrote it meant "the column", not "a million
/// blanks".
public enum RangeSelector {
    /// Finds a sheet by name, or picks the default.
    public static func sheet(
        in workbook: Workbook,
        named name: String?,
        tool: String
    ) throws(SheetError) -> (index: Int, sheet: Sheet) {
        if let name {
            guard let index = workbook.sheets.firstIndex(where: {
                $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame
            }) else {
                let available = workbook.sheets.map(\.name).joined(separator: ", ")
                throw SheetError.invalidToolArguments(
                    tool: tool,
                    detail: "no sheet named '\(name)'. This workbook has: \(available)"
                )
            }
            return (index, workbook.sheets[index])
        }
        if let index = workbook.sheets.firstIndex(where: { $0.visibility == .visible }) {
            return (index, workbook.sheets[index])
        }
        guard let first = workbook.sheets.first else {
            throw SheetError.invalidToolArguments(tool: tool, detail: "the workbook has no sheets")
        }
        return (0, first)
    }

    /// Resolves both arguments together.
    public static func target(
        in workbook: Workbook,
        sheet sheetArgument: String?,
        range rangeArgument: String?,
        tool: String
    ) throws(SheetError) -> RangeTarget {
        var sheetName = sheetArgument
        var rangeText = rangeArgument

        if let text = rangeArgument, text.contains("!") {
            guard let split = A1Notation.split(text) else {
                throw SheetError.invalidToolArguments(
                    tool: tool, detail: "'\(text)' has an unterminated quoted sheet name"
                )
            }
            if let qualified = split.sheetName {
                if let sheetArgument,
                   sheetArgument.compare(qualified, options: [.caseInsensitive]) != .orderedSame {
                    throw SheetError.invalidToolArguments(
                        tool: tool,
                        detail: "`sheet` says '\(sheetArgument)' but `range` says '\(qualified)'"
                    )
                }
                sheetName = qualified
            }
            rangeText = split.rangeText
        }

        let resolved = try sheet(in: workbook, named: sheetName, tool: tool)
        let used = resolved.sheet.usedRange
        guard let rangeText, !rangeText.isEmpty else {
            return RangeTarget(
                sheetIndex: resolved.index,
                sheetID: resolved.sheet.id,
                sheetName: resolved.sheet.name,
                range: used ?? CellRange(CellRef.origin),
                wasClamped: false
            )
        }

        let parsed = try parse(rangeText, used: used, tool: tool)
        return RangeTarget(
            sheetIndex: resolved.index,
            sheetID: resolved.sheet.id,
            sheetName: resolved.sheet.name,
            range: parsed.range,
            wasClamped: parsed.clamped
        )
    }

    /// Parses one A1 rectangle, including the two open forms.
    public static func parse(
        _ text: String,
        used: CellRange?,
        tool: String
    ) throws(SheetError) -> (range: CellRange, clamped: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard !trimmed.isEmpty else {
            throw SheetError.invalidToolArguments(tool: tool, detail: "`range` is empty")
        }

        if let open = openReference(trimmed) {
            let bounds = used ?? CellRange(CellRef.origin)
            let range: CellRange = switch open {
            case let .columns(first, last):
                CellRange(rows: bounds.rows, columns: min(first, last) ... max(first, last))
            case let .rows(first, last):
                CellRange(rows: min(first, last) ... max(first, last), columns: bounds.columns)
            }
            return (range, true)
        }

        guard let range = CellRange(a1: trimmed) else {
            throw SheetError.invalidCellReference(text: text)
        }
        guard range.isValid else {
            throw SheetError.rangeOutOfRange(
                range: text, detail: "the sheet is \(Limits.rowCount) rows by \(Limits.columnCount) columns"
            )
        }
        // `D4:A1` is the same rectangle as `A1:D4`, and refusing it would be pedantry.
        let normalised = CellRange(
            rows: min(range.start.row, range.end.row) ... max(range.start.row, range.end.row),
            columns: min(range.start.column, range.end.column) ... max(range.start.column, range.end.column)
        )
        return (normalised, false)
    }

    private enum OpenReference {
        case columns(Int, Int)
        case rows(Int, Int)
    }

    /// Recognises `A:C` and `3:7`, and nothing else — `A1:C` is a typo, not a shorthand, and
    /// guessing at what it meant is how a tool deletes the wrong rows.
    private static func openReference(_ text: String) -> OpenReference? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let first = String(parts[0]).uppercased()
        let second = String(parts[1]).uppercased()

        if first.allSatisfy(\.isLetter), second.allSatisfy(\.isLetter) {
            guard let start = CellRef.columnIndex(letters: first),
                  let end = CellRef.columnIndex(letters: second),
                  Limits.isValidColumn(start), Limits.isValidColumn(end)
            else { return nil }
            return .columns(start, end)
        }
        if first.allSatisfy(\.isNumber), second.allSatisfy(\.isNumber) {
            guard let start = Int(first), let end = Int(second), start >= 1, end >= 1,
                  Limits.isValidRow(start - 1), Limits.isValidRow(end - 1)
            else { return nil }
            return .rows(start - 1, end - 1)
        }
        return nil
    }
}
