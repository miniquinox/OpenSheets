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
/// Produced by array literals (`{1,2;3,4}`), by reading a range into a value, by operators
/// broadcasting over ranges, and by the dynamic-array functions.
///
/// An array that reaches a cell **spills**: the cell becomes an anchor and the result occupies
/// the rectangle below and to the right of it. See `FormulaEngine`'s spill handling for the
/// blocking rules and `#SPILL!`. A *reference* that reaches a cell still reduces by implicit
/// intersection, which is the pre-365 rule and what the workbooks that use it expect.
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

    /// Whether this holds exactly one scalar, and therefore behaves as one.
    public var isSingle: Bool { rowCount == 1 && columnCount == 1 }

    /// The scalar at a position under Excel's broadcast rule: an axis of length 1 repeats,
    /// and an axis that is neither 1 nor long enough yields `#N/A`.
    ///
    /// This is the whole of `{1;2;3} * {10,20}` → a 3×2 block, and of `A1:A8>0` → an 8×1
    /// block of booleans.
    public func broadcast(row: Int, column: Int) -> ScalarValue {
        let sourceRow = rowCount == 1 ? 0 : row
        let sourceColumn = columnCount == 1 ? 0 : column
        guard sourceRow < rowCount, sourceColumn < columnCount else { return .error(.notAvailable) }
        return values[sourceRow * columnCount + sourceColumn]
    }

    /// The rows as arrays of scalars.
    public var rowsOfValues: [[ScalarValue]] {
        (0 ..< rowCount).map { row in Array(values[row * columnCount ..< (row + 1) * columnCount]) }
    }

    /// The columns as arrays of scalars.
    public var columnsOfValues: [[ScalarValue]] {
        (0 ..< columnCount).map { column in (0 ..< rowCount).map { self[$0, column] } }
    }

    /// An array built from rows of equal length.
    public init(rows: [[ScalarValue]]) {
        let columns = rows.first?.count ?? 0
        self.init(rowCount: rows.count, columnCount: columns, values: rows.flatMap { $0 })
    }
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

/// A `LAMBDA(param…, body)` value: an unapplied function, with the names that were in scope
/// when it was written.
///
/// The captured environment is what makes `LET(n,3,MAP(A1:A3,LAMBDA(x,x*n)))` give the same
/// answer as Excel. Resolving `n` at *call* time instead would be dynamic scoping, which
/// happens to agree on almost every real formula and disagrees on the ones where somebody
/// shadowed a name — the class of quietly wrong number this engine exists to refuse.
public struct LambdaValue: Hashable, Sendable {
    /// Parameter names, uppercased, in declaration order.
    public var parameters: [String]
    /// The expression to evaluate once the parameters are bound.
    public var body: FormulaExpression
    /// Names visible where the lambda was written, innermost binding already flattened in.
    var captured: [String: FormulaValue]

    init(parameters: [String], body: FormulaExpression, captured: [String: FormulaValue]) {
        self.parameters = parameters
        self.body = body
        self.captured = captured
    }
}

/// Anything an expression can evaluate to.
public enum FormulaValue: Hashable, Sendable {
    /// A single value.
    case scalar(ScalarValue)
    /// A rectangular block of values with no home in the grid.
    case array(ValueArray)
    /// One or more live rectangles. Functions that care about *where* the data is — `OFFSET`,
    /// `INDEX` in reference form, `ROW`, `COLUMNS` — need this rather than the values.
    case reference(ReferenceValue)
    /// An unapplied `LAMBDA`. `indirect` because the captured environment holds
    /// ``FormulaValue``s, which would otherwise make the type infinitely sized.
    indirect case lambda(LambdaValue)

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
        case .reference, .lambda: nil
        }
    }

    /// Whether this value carries more than one cell, and so broadcasts rather than reducing.
    ///
    /// A reference counts: `A1:A8>0` is an 8×1 block of booleans in Excel 365, not the one
    /// cell implicit intersection would pick.
    var isMultiValued: Bool {
        switch self {
        case let .array(array): !array.isSingle
        case let .reference(reference): reference.parts.count == 1 && !(reference.singleRange?.range.isSingleCell ?? true)
        case .scalar, .lambda: false
        }
    }

    /// The lambda, if this is one.
    var lambdaValue: LambdaValue? { if case let .lambda(value) = self { value } else { nil } }
}

extension FormulaValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .scalar(scalar): scalar.description
        case let .array(array): "{\(array.rowCount)x\(array.columnCount)}"
        case let .reference(reference): reference.parts.map(\.description).joined(separator: ",")
        case let .lambda(lambda): "LAMBDA(\(lambda.parameters.joined(separator: ",")))"
        }
    }
}
