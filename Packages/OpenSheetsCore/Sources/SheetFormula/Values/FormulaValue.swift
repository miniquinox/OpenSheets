import Foundation
import SheetModel

// MARK: - Addressing across sheets

/// A cell, qualified by the sheet it lives on.
///
/// ``CellRef`` is deliberately sheet-agnostic, but a dependency graph spanning a workbook is
/// not: `Sheet1!A1` and `Sheet2!A1` are different nodes. This is the graph's node type and the
/// key of every map the engine hands back.
public struct SheetCell: Hashable, Sendable, Codable, Comparable {
    /// The sheet this cell lives on.
    public var sheet: SheetID
    /// The address within that sheet.
    public var ref: CellRef

    public init(sheet: SheetID, ref: CellRef) {
        self.sheet = sheet
        self.ref = ref
    }

    public init(sheet: SheetID, row: Int, column: Int) {
        self.init(sheet: sheet, ref: CellRef(row: row, column: column))
    }

    /// Sheet id first, then row-major order — a stable total order for deterministic output.
    public static func < (lhs: SheetCell, rhs: SheetCell) -> Bool {
        lhs.sheet == rhs.sheet ? lhs.ref < rhs.ref : lhs.sheet < rhs.sheet
    }
}

extension SheetCell: CustomStringConvertible {
    public var description: String { "\(sheet.rawValue)!\(ref.a1String)" }
}

/// A rectangle, qualified by the sheet it lives on.
public struct SheetRange: Hashable, Sendable, Codable {
    /// The sheet this rectangle lives on.
    public var sheet: SheetID
    /// The rectangle, normalised by ``CellRange``.
    public var range: CellRange

    public init(sheet: SheetID, range: CellRange) {
        self.sheet = sheet
        self.range = range
    }

    public init(_ cell: SheetCell) {
        sheet = cell.sheet
        range = CellRange(cell.ref)
    }

    /// Whether `cell` falls inside this rectangle, on the same sheet.
    public func contains(_ cell: SheetCell) -> Bool {
        cell.sheet == sheet && range.contains(cell.ref)
    }

    /// The top-left corner as a ``SheetCell``.
    public var topLeft: SheetCell { SheetCell(sheet: sheet, ref: range.start) }
}

extension SheetRange: CustomStringConvertible {
    public var description: String { "\(sheet.rawValue)!\(range.a1String)" }
}

// MARK: - Scalars

/// One value an expression can produce, before arrays and references get involved.
///
/// This mirrors ``CellValue`` but is a separate type on purpose: `CellValue` is what a *cell*
/// holds, and a cell can never hold `#CIRCULAR`-free intermediate state like "the blank that
/// came out of an empty cell but is not an empty string". Keeping them apart also means the
/// frozen model never grows a case for the engine's convenience.
public enum ScalarValue: Hashable, Sendable {
    /// An empty cell, or an omitted argument. Coerces to `0` in arithmetic and to `""` in
    /// concatenation, but is *not* equal to `""` — `COUNT` skips it, `COUNTA` skips it,
    /// `ISBLANK` says `TRUE`.
    case blank
    /// A number. Dates are numbers; see ``DateSystem``.
    case number(Double)
    /// Text.
    case text(String)
    /// `TRUE` or `FALSE`.
    case boolean(Bool)
    /// An error token.
    case error(CellError)

    /// Whether this is an ``error(_:)``.
    public var isError: Bool { if case .error = self { true } else { false } }

    /// The error, if this is one.
    public var errorValue: CellError? { if case let .error(value) = self { value } else { nil } }

    /// Excel's type ranking for mixed-type comparison: numbers sort before text, text before
    /// booleans. Blanks take the rank of whatever they are being compared against, so they
    /// are not listed here.
    var comparisonRank: Int {
        switch self {
        case .number: 0
        case .text: 1
        case .boolean: 2
        case .blank: 0
        case .error: 3
        }
    }
}

extension ScalarValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .blank: "<blank>"
        case let .number(value): String(value)
        case let .text(value): "\"\(value)\""
        case let .boolean(value): value ? "TRUE" : "FALSE"
        case let .error(value): value.rawValue
        }
    }
}

extension ScalarValue {
    /// Lifts a stored cell value into the expression domain.
    public init(_ value: CellValue) {
        switch value {
        case .empty: self = .blank
        case let .number(number): self = .number(number)
        case let .text(text): self = .text(text)
        case let .boolean(flag): self = .boolean(flag)
        case let .error(error): self = .error(error)
        }
    }

    /// Lowers back into a stored cell value, applying Excel's cosmetic 15-digit rounding to
    /// numbers so `0.1+0.2-0.3` lands on a clean `0` rather than `5.55e-17`.
    public var cellValue: CellValue {
        switch self {
        case .blank: .empty
        case let .number(value): .number(ExcelNumber.store(value))
        case let .text(value): .text(value)
        case let .boolean(flag): .boolean(flag)
        case let .error(error): .error(error)
        }
    }
}

// MARK: - Arrays

/// A rectangular block of scalars, row-major.
///
/// Produced by array literals (`{1,2;3,4}`), by reading a range into a value, and by the few
/// functions that return more than one cell. OpenSheets never *spills* an array into the grid
/// — that is dynamic arrays, excluded by PLAN.md §5.3 — so an array that reaches a cell is
/// reduced to its top-left element, which is what pre-365 Excel does.
public struct ValueArray: Hashable, Sendable {
    /// Rows, at least 1.
    public let rowCount: Int
    /// Columns, at least 1.
    public let columnCount: Int
    /// `rowCount * columnCount` scalars in row-major order.
    public let values: [ScalarValue]

    /// Builds an array, padding with ``ScalarValue/error(_:)`` `#N/A` if `values` is short and
    /// truncating if it is long, so the invariant `values.count == rowCount * columnCount`
    /// always holds.
    public init(rowCount: Int, columnCount: Int, values: [ScalarValue]) {
        let rows = Swift.max(rowCount, 0)
        let columns = Swift.max(columnCount, 0)
        let wanted = rows * columns
        self.rowCount = rows
        self.columnCount = columns
        if values.count == wanted {
            self.values = values
        } else if values.count > wanted {
            self.values = Array(values.prefix(wanted))
        } else {
            self.values = values + Array(repeating: .error(.notAvailable), count: wanted - values.count)
        }
    }

    /// A 1×1 array.
    public init(_ scalar: ScalarValue) {
        self.init(rowCount: 1, columnCount: 1, values: [scalar])
    }

    /// A single row.
    public init(row values: [ScalarValue]) {
        self.init(rowCount: 1, columnCount: values.count, values: values)
    }

    /// A single column.
    public init(column values: [ScalarValue]) {
        self.init(rowCount: values.count, columnCount: 1, values: values)
    }

    /// Scalars in row-major order.
    public var count: Int { values.count }

    /// The scalar at a position, or `#REF!` when the position is outside the block.
    public subscript(row: Int, column: Int) -> ScalarValue {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else {
            return .error(.invalidReference)
        }
        return values[row * columnCount + column]
    }

    /// The top-left scalar, which is what an array collapses to in a scalar context.
    public var first: ScalarValue { values.first ?? .error(.notAvailable) }
}

// MARK: - References

/// A resolved reference: one or more rectangles on named sheets.
///
/// More than one rectangle happens with the union operator, `SUM(A1:A3,C1:C3)`. Excel keeps
/// the parts separate rather than merging them into a bounding box, and so do we — merging
/// would make `SUM((A1:A2,A4:A5))` count `A3`.
public struct ReferenceValue: Hashable, Sendable {
    /// The rectangles, in the order they were written.
    public var parts: [SheetRange]

    public init(_ parts: [SheetRange]) {
        self.parts = parts
    }

    public init(_ single: SheetRange) {
        parts = [single]
    }

    /// Whether this reference is exactly one cell.
    public var isSingleCell: Bool {
        parts.count == 1 && (parts.first?.range.isSingleCell ?? false)
    }

    /// The single cell, when there is exactly one.
    public var singleCell: SheetCell? {
        guard let only = parts.first, parts.count == 1, only.range.isSingleCell else { return nil }
        return only.topLeft
    }

    /// The single rectangle, when there is exactly one.
    public var singleRange: SheetRange? {
        parts.count == 1 ? parts.first : nil
    }

    /// Cells covered, summed over the parts. Whole-column references make this enormous, so
    /// never use it to size an allocation — the evaluator walks the *populated* cells instead.
    public var cellCount: Int {
        parts.reduce(0) { $0 + $1.range.cellCount }
    }
}

// MARK: - Values

/// Anything an expression can evaluate to.
public enum FormulaValue: Hashable, Sendable {
    /// A single value.
    case scalar(ScalarValue)
    /// A rectangular block of values with no home in the grid.
    case array(ValueArray)
    /// One or more live rectangles. Functions that care about *where* the data is — `OFFSET`,
    /// `INDEX` in reference form, `ROW`, `COLUMNS` — need this rather than the values.
    case reference(ReferenceValue)

    /// A blank.
    public static let blank = FormulaValue.scalar(.blank)

    /// A number.
    public static func number(_ value: Double) -> FormulaValue { .scalar(.number(value)) }
    /// Text.
    public static func text(_ value: String) -> FormulaValue { .scalar(.text(value)) }
    /// A boolean.
    public static func boolean(_ value: Bool) -> FormulaValue { .scalar(.boolean(value)) }
    /// An error.
    public static func error(_ value: CellError) -> FormulaValue { .scalar(.error(value)) }

    /// The error this value carries, looking inside a 1×1 array but not inside a reference.
    public var errorValue: CellError? {
        switch self {
        case let .scalar(scalar): scalar.errorValue
        case let .array(array): array.count == 1 ? array.first.errorValue : nil
        case .reference: nil
        }
    }
}

extension FormulaValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .scalar(scalar): scalar.description
        case let .array(array): "{\(array.rowCount)x\(array.columnCount)}"
        case let .reference(reference): reference.parts.map(\.description).joined(separator: ",")
        }
    }
}
