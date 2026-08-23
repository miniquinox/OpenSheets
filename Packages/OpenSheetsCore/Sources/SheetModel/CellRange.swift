import Foundation

/// A rectangular block of cells, inclusive of both corners.
///
/// **The initialiser normalises.** `CellRange(start: B5, end: A1)` is stored as `A1:B5`, so
/// `start` is always the top-left corner and `end` always the bottom-right. A drag-select
/// upward and a drag-select downward produce the same value, and every consumer can assume
/// `start <= end` on both axes without checking. Six agents each writing their own
/// `min`/`max` dance is exactly the bug this prevents.
///
/// Whole-column and whole-row references from formulas (`A:A`, `1:1`) are represented as
/// ordinary ranges spanning the sheet's full extent — see ``entireColumn(_:)`` and
/// ``entireRow(_:)``. There is no separate type for them, because everything that consumes a
/// range wants a rectangle.
public struct CellRange: Hashable, Sendable, Codable {
    /// Top-left corner, inclusive.
    public let start: CellRef

    /// Bottom-right corner, inclusive.
    public let end: CellRef

    /// Builds a range from two opposite corners in any order, normalising so `start` is
    /// top-left. Does not validate that either corner is on the sheet — see ``validated()``.
    public init(start: CellRef, end: CellRef) {
        self.start = CellRef(row: Swift.min(start.row, end.row), column: Swift.min(start.column, end.column))
        self.end = CellRef(row: Swift.max(start.row, end.row), column: Swift.max(start.column, end.column))
    }

    /// A range covering exactly one cell.
    public init(_ ref: CellRef) {
        start = ref
        end = ref
    }

    /// A range from explicit bounds, in any order.
    public init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        self.init(
            start: CellRef(row: rows.lowerBound, column: columns.lowerBound),
            end: CellRef(row: rows.upperBound, column: columns.upperBound)
        )
    }

    /// Every addressable cell, `A1:XFD1048576`.
    public static let entireSheet = CellRange(
        start: CellRef(row: 0, column: 0),
        end: CellRef(row: Limits.maxRow, column: Limits.maxColumn)
    )

    /// One whole column, top to bottom — what `A:A` means in a formula.
    public static func entireColumn(_ column: Int) -> CellRange {
        CellRange(rows: 0 ... Limits.maxRow, columns: column ... column)
    }

    /// One whole row, left to right — what `1:1` means in a formula.
    public static func entireRow(_ row: Int) -> CellRange {
        CellRange(rows: row ... row, columns: 0 ... Limits.maxColumn)
    }

    // MARK: - Geometry

    /// Rows spanned, always at least 1.
    public var rowCount: Int { end.row - start.row + 1 }

    /// Columns spanned, always at least 1.
    public var columnCount: Int { end.column - start.column + 1 }

    /// Cells enclosed. `Int` overflow is impossible: the grid caps this at about 1.7e10.
    public var cellCount: Int { rowCount * columnCount }

    /// Whether this range covers exactly one cell.
    public var isSingleCell: Bool { start == end }

    /// The rows this range spans, as a range you can iterate.
    public var rows: ClosedRange<Int> { start.row ... end.row }

    /// The columns this range spans, as a range you can iterate.
    public var columns: ClosedRange<Int> { start.column ... end.column }

    /// Whether both corners are on the sheet.
    public var isValid: Bool { start.isValid && end.isValid }

    /// Self, or a thrown ``SheetError``.
    @discardableResult
    public func validated() throws(SheetError) -> CellRange {
        guard isValid else {
            throw SheetError.rangeOutOfRange(range: a1String, detail: "outside A1:XFD1048576")
        }
        return self
    }

    /// Whether `ref` falls inside this rectangle.
    public func contains(_ ref: CellRef) -> Bool {
        ref.row >= start.row && ref.row <= end.row
            && ref.column >= start.column && ref.column <= end.column
    }

    /// Whether `other` fits entirely inside this rectangle.
    public func contains(_ other: CellRange) -> Bool {
        contains(other.start) && contains(other.end)
    }

    /// Whether the two rectangles share at least one cell.
    public func intersects(_ other: CellRange) -> Bool {
        start.row <= other.end.row && other.start.row <= end.row
            && start.column <= other.end.column && other.start.column <= end.column
    }

    /// The overlap, or `nil` when they do not touch.
    public func intersection(_ other: CellRange) -> CellRange? {
        guard intersects(other) else { return nil }
        return CellRange(
            rows: Swift.max(start.row, other.start.row) ... Swift.min(end.row, other.end.row),
            columns: Swift.max(start.column, other.start.column) ... Swift.min(end.column, other.end.column)
        )
    }

    /// The smallest rectangle containing both. Note this covers cells in neither input when
    /// the two are diagonal to each other — that is what a bounding box means, and it is what
    /// `usedRange` wants.
    public func union(_ other: CellRange) -> CellRange {
        CellRange(
            rows: Swift.min(start.row, other.start.row) ... Swift.max(end.row, other.end.row),
            columns: Swift.min(start.column, other.start.column) ... Swift.max(end.column, other.end.column)
        )
    }

    /// This rectangle pulled back inside `bounds`, or `nil` when they do not overlap at all.
    public func clamped(to bounds: CellRange) -> CellRange? {
        intersection(bounds)
    }

    /// This rectangle pulled back inside the addressable grid.
    public var clampedToSheet: CellRange {
        CellRange(start: start.clamped, end: end.clamped)
    }

    /// This rectangle moved by a signed delta. Does not clamp or validate.
    public func offset(rows: Int = 0, columns: Int = 0) -> CellRange {
        CellRange(start: start.offset(rows: rows, columns: columns), end: end.offset(rows: rows, columns: columns))
    }
}

// MARK: - Iteration

extension CellRange: Sequence {
    /// Walks the rectangle in row-major order — across each row, then down.
    ///
    /// The same order cells are stored and written in, so a loop over a range and a loop over
    /// the store visit cells in the same sequence. Beware ``cellCount``: iterating
    /// ``entireSheet`` is 17 billion steps, which is a hang, not a loop.
    public struct Iterator: IteratorProtocol, Sendable {
        private let range: CellRange
        private var row: Int
        private var column: Int
        private var finished: Bool

        init(_ range: CellRange) {
            self.range = range
            row = range.start.row
            column = range.start.column
            finished = range.start.row > range.end.row || range.start.column > range.end.column
        }

        public mutating func next() -> CellRef? {
            guard !finished else { return nil }
            let result = CellRef(row: row, column: column)
            if column < range.end.column {
                column += 1
            } else if row < range.end.row {
                column = range.start.column
                row += 1
            } else {
                finished = true
            }
            return result
        }
    }

    public func makeIterator() -> Iterator { Iterator(self) }

    /// `Sequence` would otherwise walk the whole rectangle to count it.
    public var underestimatedCount: Int { cellCount }
}

// MARK: - A1 notation

extension CellRange {
    /// Parses `"A1:B5"`, or a bare `"A1"` as a single-cell range. Rejects `$` anchors and
    /// sheet qualifiers — for those, use ``A1Notation``.
    public init?(a1 text: some StringProtocol) {
        if let colon = text.firstIndex(of: ":") {
            guard let first = CellRef(a1: text[text.startIndex ..< colon]),
                  let second = CellRef(a1: text[text.index(after: colon)...])
            else { return nil }
            self.init(start: first, end: second)
        } else {
            guard let single = CellRef(a1: text) else { return nil }
            self.init(single)
        }
    }

    /// Convenience spelling of ``init(a1:)``.
    public init?(_ a1: some StringProtocol) {
        self.init(a1: a1)
    }

    /// `"A1:B5"`, collapsing a single-cell range to `"A1"`.
    ///
    /// Excel accepts both `A1` and `A1:A1` and writes whichever the producer felt like, so
    /// pass `collapseSingleCell: false` where a schema demands the two-corner form — the
    /// `dimension` attribute is the one place that matters.
    public func a1String(collapseSingleCell: Bool = true) -> String {
        if collapseSingleCell, isSingleCell { return start.a1String }
        return "\(start.a1String):\(end.a1String)"
    }

    /// `"A1:B5"`, collapsing single cells. See ``a1String(collapseSingleCell:)``.
    public var a1String: String { a1String() }
}

extension CellRange: CustomStringConvertible {
    public var description: String { a1String }
}
