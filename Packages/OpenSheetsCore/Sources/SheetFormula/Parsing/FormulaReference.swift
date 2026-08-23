import Foundation
import SheetModel

/// The sheet (and possibly workbook) half of a reference.
///
/// `nil` on a ``FormulaReference`` means "the sheet the formula lives on", which is what an
/// unqualified `A1` means. A non-`nil` qualifier is kept as *text*, not as a ``SheetID``,
/// because a formula must round-trip a reference to a sheet that does not exist — Excel writes
/// them, and rewriting `Sheet9!A1` as `#REF!` because we could not resolve `Sheet9` would
/// destroy a file we were only asked to shift a row on.
public struct SheetQualifier: Hashable, Sendable {
    /// The `[1]` or `[Book1.xlsx]` prefix of an external reference, brackets included.
    /// Non-`nil` means we will never evaluate this reference: PLAN.md §7.3 says we do not open
    /// other workbooks.
    public var workbook: String?

    /// The sheet name, already unquoted and unescaped.
    public var name: String

    /// The far end of a 3-D span, `Sheet1:Sheet3!A1`. We parse these so they survive an edit;
    /// we do not evaluate them.
    public var throughName: String?

    public init(workbook: String? = nil, name: String, throughName: String? = nil) {
        self.workbook = workbook
        self.name = name
        self.throughName = throughName
    }

    /// Whether this reference reaches outside the current workbook.
    public var isExternal: Bool { workbook != nil }

    /// Whether this reference spans several sheets.
    public var isThreeDimensional: Bool { throughName != nil }

    /// The qualifier as it appears in a formula, including the trailing `!`.
    public var text: String {
        var result = workbook ?? ""
        let needsQuotes = A1Notation.needsQuoting(name) || (throughName.map(A1Notation.needsQuoting) ?? false)
        if let throughName {
            if needsQuotes {
                result += "'\(escape(name)):\(escape(throughName))'"
            } else {
                result += "\(name):\(throughName)"
            }
        } else {
            result += needsQuotes ? "'\(escape(name))'" : name
        }
        return result + "!"
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

/// One corner of a reference: an address plus whether each axis is anchored with `$`.
public struct ReferenceEndpoint: Hashable, Sendable {
    /// 0-based row.
    public var row: Int
    /// 0-based column.
    public var column: Int
    /// `$` before the row number.
    public var rowIsAbsolute: Bool
    /// `$` before the column letters.
    public var columnIsAbsolute: Bool

    public init(row: Int, column: Int, rowIsAbsolute: Bool = false, columnIsAbsolute: Bool = false) {
        self.row = row
        self.column = column
        self.rowIsAbsolute = rowIsAbsolute
        self.columnIsAbsolute = columnIsAbsolute
    }

    /// The address, dropping the anchoring.
    public var ref: CellRef { CellRef(row: row, column: column) }
}

/// What kind of rectangle a reference names.
public enum ReferenceShape: String, Sendable, Hashable, Codable, CaseIterable {
    /// `A1` or `A1:B9`.
    case cells
    /// `A:A`, `B:D` — every row of those columns.
    case columns
    /// `1:1`, `2:10` — every column of those rows.
    case rows
}

/// A reference exactly as written in a formula.
///
/// This keeps three things a plain ``CellRange`` cannot, and each of them is load-bearing for
/// a different consumer:
///
/// - **Anchoring** (`$A$1` versus `A1`) — A8 needs it for fill-down.
/// - **Shape** — `A:A` must come back out as `A:A`. Expanding it to `A1:A1048576` produces a
///   formula that means the same thing, is 15 characters longer, and is not what the user
///   typed. It also breaks the row-insert rule: inserting a row inside `A:A` must not widen it
///   past the sheet.
/// - **The sheet as text** — see ``SheetQualifier``.
public struct FormulaReference: Hashable, Sendable {
    /// The sheet, or `nil` for "wherever this formula lives".
    public var qualifier: SheetQualifier?
    /// Whether this names cells, whole columns, or whole rows.
    public var shape: ReferenceShape
    /// Top-left corner. For ``ReferenceShape/columns`` the row fields are ignored.
    public var start: ReferenceEndpoint
    /// Bottom-right corner.
    public var end: ReferenceEndpoint
    /// The reference was destroyed by a delete and now spells `#REF!`.
    public var isDeleted: Bool

    public init(
        qualifier: SheetQualifier? = nil,
        shape: ReferenceShape = .cells,
        start: ReferenceEndpoint,
        end: ReferenceEndpoint,
        isDeleted: Bool = false
    ) {
        self.qualifier = qualifier
        self.shape = shape
        self.start = start
        self.end = end
        self.isDeleted = isDeleted
    }

    /// A single-cell reference.
    public init(_ ref: CellRef, absoluteRow: Bool = false, absoluteColumn: Bool = false, sheet: SheetQualifier? = nil) {
        let endpoint = ReferenceEndpoint(
            row: ref.row, column: ref.column, rowIsAbsolute: absoluteRow, columnIsAbsolute: absoluteColumn
        )
        self.init(qualifier: sheet, shape: .cells, start: endpoint, end: endpoint)
    }

    /// A reference that has been deleted out of existence.
    public static func deleted(qualifier: SheetQualifier? = nil) -> FormulaReference {
        FormulaReference(
            qualifier: qualifier,
            shape: .cells,
            start: ReferenceEndpoint(row: 0, column: 0),
            end: ReferenceEndpoint(row: 0, column: 0),
            isDeleted: true
        )
    }

    /// Whether this names exactly one cell.
    public var isSingleCell: Bool {
        shape == .cells && start.row == end.row && start.column == end.column
    }

    /// The rectangle this reference covers, with whole-column and whole-row shapes expanded to
    /// the sheet's full extent.
    public var range: CellRange {
        switch shape {
        case .cells:
            CellRange(start: start.ref, end: end.ref)
        case .columns:
            CellRange(rows: 0 ... Limits.maxRow, columns: min(start.column, end.column) ... max(start.column, end.column))
        case .rows:
            CellRange(
                rows: min(start.row, end.row) ... max(start.row, end.row),
                columns: 0 ... Limits.maxColumn
            )
        }
    }

    /// Whether both corners are on the sheet for the axes this shape uses.
    public var isOnSheet: Bool {
        switch shape {
        case .cells:
            Limits.isValidRow(start.row) && Limits.isValidRow(end.row)
                && Limits.isValidColumn(start.column) && Limits.isValidColumn(end.column)
        case .columns:
            Limits.isValidColumn(start.column) && Limits.isValidColumn(end.column)
        case .rows:
            Limits.isValidRow(start.row) && Limits.isValidRow(end.row)
        }
    }
}

// MARK: - A1 text

extension FormulaReference {
    /// Parses the text of a lexer ``FormulaToken/Kind/reference(_:)`` token.
    public init?(a1Text text: String) {
        var body = Substring(text)
        var qualifier: SheetQualifier?

        if let separator = FormulaReference.sheetSeparator(in: body) {
            guard let parsed = FormulaReference.parseQualifier(body[body.startIndex ..< separator]) else { return nil }
            qualifier = parsed
            body = body[body.index(after: separator)...]
        }

        if body == "#REF!" {
            self = .deleted(qualifier: qualifier)
            return
        }

        let halves = FormulaReference.splitOnRangeColon(body)
        guard let firstText = halves.first else { return nil }
        if halves.contains("#REF!") {
            self = .deleted(qualifier: qualifier)
            return
        }

        guard let first = FormulaReference.parsePart(firstText) else { return nil }
        guard halves.count == 2 else {
            guard case let .cell(endpoint) = first else { return nil }
            self.init(qualifier: qualifier, shape: .cells, start: endpoint, end: endpoint)
            return
        }
        guard let second = FormulaReference.parsePart(halves[1]) else { return nil }

        switch (first, second) {
        case let (.cell(a), .cell(b)):
            self.init(qualifier: qualifier, shape: .cells, start: FormulaReference.topLeft(a, b), end: FormulaReference.bottomRight(a, b))
        case let (.column(a), .column(b)):
            self.init(
                qualifier: qualifier, shape: .columns,
                start: a.column <= b.column ? a : b,
                end: a.column <= b.column ? b : a
            )
        case let (.row(a), .row(b)):
            self.init(
                qualifier: qualifier, shape: .rows,
                start: a.row <= b.row ? a : b,
                end: a.row <= b.row ? b : a
            )
        default:
            return nil
        }
    }

    private enum Part {
        case cell(ReferenceEndpoint)
        case column(ReferenceEndpoint)
        case row(ReferenceEndpoint)
    }

    private static func topLeft(_ a: ReferenceEndpoint, _ b: ReferenceEndpoint) -> ReferenceEndpoint {
        // Anchoring belongs to the corner it was written on, so normalising a backwards range
        // has to carry each `$` with its own coordinate.
        ReferenceEndpoint(
            row: Swift.min(a.row, b.row),
            column: Swift.min(a.column, b.column),
            rowIsAbsolute: a.row <= b.row ? a.rowIsAbsolute : b.rowIsAbsolute,
            columnIsAbsolute: a.column <= b.column ? a.columnIsAbsolute : b.columnIsAbsolute
        )
    }

    private static func bottomRight(_ a: ReferenceEndpoint, _ b: ReferenceEndpoint) -> ReferenceEndpoint {
        ReferenceEndpoint(
            row: Swift.max(a.row, b.row),
            column: Swift.max(a.column, b.column),
            rowIsAbsolute: a.row <= b.row ? b.rowIsAbsolute : a.rowIsAbsolute,
            columnIsAbsolute: a.column <= b.column ? b.columnIsAbsolute : a.columnIsAbsolute
        )
    }

    private static func parsePart(_ text: Substring) -> Part? {
        var columnAbsolute = false
        var rowAbsolute = false
        var letters = ""
        var digits = ""
        var stage = 0
        for character in text {
            if character == "$" {
                if stage == 0 { columnAbsolute = true } else if stage == 1 { rowAbsolute = true } else { return nil }
                continue
            }
            if character.isLetter {
                guard stage <= 1, digits.isEmpty else { return nil }
                stage = 1
                letters.append(character)
                continue
            }
            if character.isNumber {
                stage = 2
                digits.append(character)
                continue
            }
            return nil
        }
        if !letters.isEmpty, !digits.isEmpty {
            guard let column = CellRef.columnIndex(letters: letters), let row = Int(digits), row >= 1,
                  row <= Limits.rowCount
            else { return nil }
            return .cell(ReferenceEndpoint(
                row: row - 1, column: column, rowIsAbsolute: rowAbsolute, columnIsAbsolute: columnAbsolute
            ))
        }
        if !letters.isEmpty {
            guard !rowAbsolute, let column = CellRef.columnIndex(letters: letters) else { return nil }
            return .column(ReferenceEndpoint(row: 0, column: column, columnIsAbsolute: columnAbsolute))
        }
        if !digits.isEmpty {
            // `$1` anchors the row even though the `$` sits where a column anchor normally is.
            guard let row = Int(digits), row >= 1, row <= Limits.rowCount else { return nil }
            return .row(ReferenceEndpoint(row: row - 1, column: 0, rowIsAbsolute: columnAbsolute || rowAbsolute))
        }
        return nil
    }

    /// The `!` that separates the sheet from the address, skipping any inside quotes.
    private static func sheetSeparator(in text: Substring) -> Substring.Index? {
        var inQuotes = false
        var index = text.startIndex
        var result: Substring.Index?
        while index < text.endIndex {
            let character = text[index]
            if character == "'" { inQuotes.toggle() }
            if character == "!", !inQuotes { result = index }
            index = text.index(after: index)
        }
        return result
    }

    private static func splitOnRangeColon(_ text: Substring) -> [Substring] {
        // `#REF!` contains no colon, so a plain split is safe once the sheet half is gone.
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 ? [parts[0], parts[1]] : [text]
    }

    private static func parseQualifier(_ text: Substring) -> SheetQualifier? {
        var body = text
        var workbook: String?
        if body.hasPrefix("["), let close = body.firstIndex(of: "]") {
            workbook = String(body[body.startIndex ... close])
            body = body[body.index(after: close)...]
        }
        var name = String(body)
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard !name.isEmpty else { return nil }
        if let colon = name.firstIndex(of: ":") {
            let first = String(name[name.startIndex ..< colon])
            let second = String(name[name.index(after: colon)...])
            guard !first.isEmpty, !second.isEmpty else { return nil }
            return SheetQualifier(workbook: workbook, name: first, throughName: second)
        }
        return SheetQualifier(workbook: workbook, name: name)
    }

    /// The reference as it would be written in a formula.
    public var a1Text: String {
        let prefix = qualifier?.text ?? ""
        guard !isDeleted else { return prefix + "#REF!" }
        switch shape {
        case .cells:
            let head = start.ref.a1String(absoluteColumn: start.columnIsAbsolute, absoluteRow: start.rowIsAbsolute)
            if isSingleCell { return prefix + head }
            let tail = end.ref.a1String(absoluteColumn: end.columnIsAbsolute, absoluteRow: end.rowIsAbsolute)
            return prefix + head + ":" + tail
        case .columns:
            let head = (start.columnIsAbsolute ? "$" : "") + CellRef.columnLetters(start.column)
            let tail = (end.columnIsAbsolute ? "$" : "") + CellRef.columnLetters(end.column)
            return prefix + head + ":" + tail
        case .rows:
            let head = (start.rowIsAbsolute ? "$" : "") + String(start.row + 1)
            let tail = (end.rowIsAbsolute ? "$" : "") + String(end.row + 1)
            return prefix + head + ":" + tail
        }
    }
}

// MARK: - R1C1 text

extension FormulaReference {
    /// Parses `R1C1`, `R[-1]C`, `RC[2]`, `R1C1:R3C4`, `C2:C4`, `R1:R3`.
    ///
    /// Needs the anchor because R1C1's relative form *is* an offset: `R[-1]C` means "one row
    /// up, same column", which is a different cell in every cell it appears in.
    public init?(r1c1Text text: String, anchor: CellRef) {
        var body = Substring(text)
        var qualifier: SheetQualifier?
        if let separator = FormulaReference.sheetSeparator(in: body) {
            guard let parsed = FormulaReference.parseQualifier(body[body.startIndex ..< separator]) else { return nil }
            qualifier = parsed
            body = body[body.index(after: separator)...]
        }

        let halves = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let firstText = halves.first,
              let first = FormulaReference.parseR1C1Part(firstText, anchor: anchor)
        else { return nil }

        guard halves.count == 2 else {
            // A part naming only one axis is a whole column or a whole row: `C[-2]` is the
            // column two to the left, top to bottom, and `R3` is all of row 3.
            let endpoint = first.endpoint
            if first.hasRow, first.hasColumn {
                self.init(qualifier: qualifier, shape: .cells, start: endpoint, end: endpoint)
            } else if first.hasColumn {
                self.init(qualifier: qualifier, shape: .columns, start: endpoint, end: endpoint)
            } else {
                self.init(qualifier: qualifier, shape: .rows, start: endpoint, end: endpoint)
            }
            return
        }
        guard let second = FormulaReference.parseR1C1Part(halves[1], anchor: anchor) else { return nil }

        if first.hasRow, first.hasColumn, second.hasRow, second.hasColumn {
            self.init(
                qualifier: qualifier, shape: .cells,
                start: FormulaReference.topLeft(first.endpoint, second.endpoint),
                end: FormulaReference.bottomRight(first.endpoint, second.endpoint)
            )
            return
        }
        if first.hasColumn, !first.hasRow, second.hasColumn, !second.hasRow {
            let a = first.endpoint
            let b = second.endpoint
            self.init(qualifier: qualifier, shape: .columns, start: a.column <= b.column ? a : b, end: a.column <= b.column ? b : a)
            return
        }
        if first.hasRow, !first.hasColumn, second.hasRow, !second.hasColumn {
            let a = first.endpoint
            let b = second.endpoint
            self.init(qualifier: qualifier, shape: .rows, start: a.row <= b.row ? a : b, end: a.row <= b.row ? b : a)
            return
        }
        return nil
    }

    private struct R1C1Part {
        var endpoint: ReferenceEndpoint
        var hasRow: Bool
        var hasColumn: Bool
    }

    private static func parseR1C1Part(_ text: Substring, anchor: CellRef) -> R1C1Part? {
        var row = anchor.row
        var column = anchor.column
        var rowAbsolute = false
        var columnAbsolute = false
        var hasRow = false
        var hasColumn = false

        var index = text.startIndex
        while index < text.endIndex {
            let axis = text[index]
            guard axis == "R" || axis == "r" || axis == "C" || axis == "c" else { return nil }
            let isRow = axis == "R" || axis == "r"
            if isRow ? hasRow : hasColumn { return nil }
            index = text.index(after: index)

            var absolute = true
            var digits = ""
            if index < text.endIndex, text[index] == "[" {
                absolute = false
                index = text.index(after: index)
                while index < text.endIndex, text[index] != "]" {
                    digits.append(text[index])
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { return nil }
                index = text.index(after: index)
                guard Int(digits) != nil else { return nil }
            } else {
                while index < text.endIndex, text[index].isNumber || text[index] == "-" {
                    digits.append(text[index])
                    index = text.index(after: index)
                }
                if digits.isEmpty { absolute = false }
            }
            let offset = Int(digits) ?? 0

            if isRow {
                hasRow = true
                rowAbsolute = absolute && !digits.isEmpty
                row = rowAbsolute ? offset - 1 : anchor.row + offset
            } else {
                hasColumn = true
                columnAbsolute = absolute && !digits.isEmpty
                column = columnAbsolute ? offset - 1 : anchor.column + offset
            }
        }
        guard hasRow || hasColumn else { return nil }
        return R1C1Part(
            endpoint: ReferenceEndpoint(
                row: row, column: column, rowIsAbsolute: rowAbsolute, columnIsAbsolute: columnAbsolute
            ),
            hasRow: hasRow,
            hasColumn: hasColumn
        )
    }

    /// The reference in R1C1 form, relative to `anchor`.
    public func r1c1Text(anchor: CellRef) -> String {
        let prefix = qualifier?.text ?? ""
        guard !isDeleted else { return prefix + "#REF!" }
        switch shape {
        case .cells:
            let head = FormulaReference.r1c1Endpoint(start, anchor: anchor)
            if isSingleCell { return prefix + head }
            return prefix + head + ":" + FormulaReference.r1c1Endpoint(end, anchor: anchor)
        case .columns:
            let head = FormulaReference.r1c1Axis(
                "C", index: start.column, absolute: start.columnIsAbsolute, anchor: anchor.column
            )
            guard start.column != end.column else { return prefix + head }
            let tail = FormulaReference.r1c1Axis(
                "C", index: end.column, absolute: end.columnIsAbsolute, anchor: anchor.column
            )
            return prefix + head + ":" + tail
        case .rows:
            let head = FormulaReference.r1c1Axis(
                "R", index: start.row, absolute: start.rowIsAbsolute, anchor: anchor.row
            )
            guard start.row != end.row else { return prefix + head }
            let tail = FormulaReference.r1c1Axis(
                "R", index: end.row, absolute: end.rowIsAbsolute, anchor: anchor.row
            )
            return prefix + head + ":" + tail
        }
    }

    private static func r1c1Endpoint(_ endpoint: ReferenceEndpoint, anchor: CellRef) -> String {
        r1c1Axis("R", index: endpoint.row, absolute: endpoint.rowIsAbsolute, anchor: anchor.row)
            + r1c1Axis("C", index: endpoint.column, absolute: endpoint.columnIsAbsolute, anchor: anchor.column)
    }

    private static func r1c1Axis(_ axis: String, index: Int, absolute: Bool, anchor: Int) -> String {
        if absolute { return axis + String(index + 1) }
        let offset = index - anchor
        return offset == 0 ? axis : "\(axis)[\(offset)]"
    }
}
