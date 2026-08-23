import Foundation
import SheetModel

/// One call to one function, with its arguments already evaluated.
///
/// The accessors on this type are where Excel's per-argument coercion rules live. They matter
/// more than they look: `SUM("42")` is `42` and `SUM(A1)` with `"42"` in `A1` is `0`, so
/// "read this argument as a number" is genuinely two different operations depending on whether
/// the value arrived directly or through a reference. ``numbers(from:)`` and ``number(_:)``
/// are those two operations.
struct FunctionCallSite {
    /// Arguments in source order. An omitted one is ``FormulaValue/blank``.
    let arguments: [FormulaValue]
    /// The shared state of this evaluation pass.
    let scope: EvaluationScope
    /// The cell whose formula is being evaluated — `ROW()`, implicit intersection, and
    /// relative `OFFSET` all need it.
    let origin: SheetCell
    /// The function's display name, for error messages.
    let name: String

    var count: Int { arguments.count }

    // MARK: - Scalar access

    /// Argument `index` reduced to a single value.
    ///
    /// A multi-cell reference is resolved by **implicit intersection**: `=A1:A10` written in a
    /// cell on row 3 means `A3`. That is Excel's pre-365 rule, and it is what a workbook
    /// written before dynamic arrays expects.
    func scalar(_ index: Int) throws -> ScalarValue {
        guard index < arguments.count else { return .blank }
        return try FunctionCallSite.reduce(arguments[index], at: origin, scope: scope)
    }

    /// Reduces a value to a scalar, applying implicit intersection to references.
    static func reduce(_ value: FormulaValue, at origin: SheetCell, scope: EvaluationScope) throws -> ScalarValue {
        switch value {
        case .lambda:
            // A lambda that reaches a value context was never applied. Excel shows `#CALC!`
            // for a cell whose result is a function, and so do we.
            throw FormulaFault.cell(.calculation)
        case let .scalar(scalar):
            return scalar
        case let .array(array):
            return array.first
        case let .reference(reference):
            guard let part = reference.parts.first, reference.parts.count == 1 else {
                throw FormulaFault.cell(.wrongType)
            }
            if part.range.isSingleCell { return scope.value(at: part.topLeft) }
            if part.sheet == origin.sheet {
                if part.range.rowCount == 1, part.range.columns.contains(origin.ref.column) {
                    return scope.value(at: SheetCell(sheet: part.sheet, row: part.range.start.row, column: origin.ref.column))
                }
                if part.range.columnCount == 1, part.range.rows.contains(origin.ref.row) {
                    return scope.value(at: SheetCell(sheet: part.sheet, row: origin.ref.row, column: part.range.start.column))
                }
            }
            throw FormulaFault.cell(.wrongType)
        }
    }

    /// Argument `index` as a number, using arithmetic coercion (text that looks numeric is
    /// converted; text that does not is `#VALUE!`).
    func number(_ index: Int) throws -> Double {
        try FunctionCallSite.number(from: try scalar(index), dateSystem: scope.options.dateSystem)
    }

    static func number(from scalar: ScalarValue, dateSystem: DateSystem) throws -> Double {
        switch Coercion.arithmeticNumber(scalar, dateSystem: dateSystem) {
        case let .success(value): return value
        case let .failure(error): throw FormulaFault.cell(error)
        }
    }

    /// Argument `index` as a number, or `fallback` when it is absent or blank.
    func number(_ index: Int, default fallback: Double) throws -> Double {
        guard index < arguments.count else { return fallback }
        let value = try scalar(index)
        if case .blank = value { return fallback }
        return try FunctionCallSite.number(from: value, dateSystem: scope.options.dateSystem)
    }

    /// Argument `index` truncated toward zero, the way Excel treats a count or an index.
    func integer(_ index: Int) throws -> Int {
        let value = try number(index)
        guard value.isFinite, value >= -1e15, value <= 1e15 else { throw FormulaFault.cell(.invalidNumber) }
        return Int(value.rounded(.towardZero))
    }

    /// Argument `index` truncated toward zero, or `fallback` when absent or blank.
    func integer(_ index: Int, default fallback: Int) throws -> Int {
        guard index < arguments.count else { return fallback }
        let value = try scalar(index)
        if case .blank = value { return fallback }
        return try integer(index)
    }

    /// Argument `index` as text.
    func text(_ index: Int) throws -> String {
        switch Coercion.text(try scalar(index)) {
        case let .success(value): return value
        case let .failure(error): throw FormulaFault.cell(error)
        }
    }

    /// Argument `index` as a boolean, or `fallback` when absent or blank.
    func boolean(_ index: Int, default fallback: Bool) throws -> Bool {
        guard index < arguments.count else { return fallback }
        let value = try scalar(index)
        if case .blank = value { return fallback }
        switch Coercion.boolean(value) {
        case let .success(flag): return flag
        case let .failure(error): throw FormulaFault.cell(error)
        }
    }

    /// Whether argument `index` was supplied at all.
    func isPresent(_ index: Int) -> Bool {
        guard index < arguments.count else { return false }
        if case .scalar(.blank) = arguments[index] { return false }
        return true
    }

    // MARK: - Reference access

    /// Argument `index` as a live reference. `#VALUE!` for anything else — `ROW(1)` is not a
    /// reference and Excel says so.
    func reference(_ index: Int) throws -> ReferenceValue {
        guard index < arguments.count, case let .reference(reference) = arguments[index] else {
            throw FormulaFault.cell(.wrongType)
        }
        return reference
    }

    /// Argument `index` as a single rectangle.
    func range(_ index: Int) throws -> SheetRange {
        guard let single = try reference(index).singleRange else { throw FormulaFault.cell(.wrongType) }
        return single
    }

    /// Argument `index` as a rectangle of values, whether it came from a reference, an array
    /// literal, or a lone scalar.
    func table(_ index: Int) throws -> ValueArray {
        guard index < arguments.count else { throw FormulaFault.cell(.wrongType) }
        return try FunctionCallSite.table(arguments[index], scope: scope)
    }

    static func table(_ value: FormulaValue, scope: EvaluationScope) throws -> ValueArray {
        switch value {
        case .lambda:
            throw FormulaFault.cell(.calculation)
        case let .scalar(scalar):
            return ValueArray(scalar)
        case let .array(array):
            return array
        case let .reference(reference):
            guard let part = reference.singleRange else { throw FormulaFault.cell(.wrongType) }
            let clipped = FunctionCallSite.materialisable(part, scope: scope)
            let rows = clipped.rowCount
            let columns = clipped.columnCount
            guard rows * columns <= scope.options.maxCellsPerAggregate else {
                throw FormulaFault.cell(.invalidNumber)
            }
            var values = [ScalarValue](repeating: .blank, count: rows * columns)
            scope.forEachPopulated(in: SheetRange(sheet: part.sheet, range: clipped)) { cell, scalar in
                let row = cell.ref.row - clipped.start.row
                let column = cell.ref.column - clipped.start.column
                values[row * columns + column] = scalar
            }
            return ValueArray(rowCount: rows, columnCount: columns, values: values)
        }
    }

    /// The rectangle to actually materialise for a reference.
    ///
    /// `SUM(A:A)` names 1,048,576 cells and means about six. Building the declared rectangle
    /// would allocate 16 MB to hold blanks, so the bottom-right corner is pulled back to the
    /// sheet's used range — the **top-left is never moved**, because every consumer of a
    /// materialised table indexes from it and shifting it would silently offset every lookup.
    ///
    /// All whole-column references on one sheet clamp to the same corner, so two ranges that
    /// were the same shape before clamping are still the same shape after — which is what
    /// `SUMIFS(A:A,B:B,">0")` depends on.
    static func materialisable(_ part: SheetRange, scope: EvaluationScope) -> CellRange {
        let clipped = part.range.clampedToSheet
        guard let used = scope.workbook[part.sheet]?.cells.usedRange else {
            return CellRange(clipped.start)
        }
        return CellRange(
            start: clipped.start,
            end: CellRef(
                row: Swift.max(clipped.start.row, Swift.min(clipped.end.row, used.end.row)),
                column: Swift.max(clipped.start.column, Swift.min(clipped.end.column, used.end.column))
            )
        )
    }

    /// The shape a reference *declares*, which is not the shape ``table(_:)`` materialises.
    ///
    /// `ROWS(A:A)` is 1,048,576 even on an empty sheet.
    func shape(_ index: Int) throws -> (rows: Int, columns: Int) {
        guard index < arguments.count else { throw FormulaFault.cell(.wrongType) }
        if case let .reference(reference) = arguments[index], let part = reference.singleRange {
            return (part.range.rowCount, part.range.columnCount)
        }
        let table = try table(index)
        return (table.rowCount, table.columnCount)
    }

    // MARK: - Aggregation

    /// Every value an argument contributes to an aggregate, tagged with whether it arrived
    /// through a reference.
    ///
    /// The tag is the whole point: `SUM` coerces a direct `"42"` and skips a referenced one.
    func elements(from index: Int) throws -> [(value: ScalarValue, viaReference: Bool)] {
        var result: [(value: ScalarValue, viaReference: Bool)] = []
        try appendElements(from: index, into: &result)
        return result
    }

    /// Every value from arguments `index...`, in order.
    func allElements(from index: Int) throws -> [(value: ScalarValue, viaReference: Bool)] {
        var result: [(value: ScalarValue, viaReference: Bool)] = []
        for position in index ..< arguments.count {
            try appendElements(from: position, into: &result)
        }
        return result
    }

    private func appendElements(
        from index: Int, into result: inout [(value: ScalarValue, viaReference: Bool)]
    ) throws {
        guard index < arguments.count else { return }
        switch arguments[index] {
        case .lambda:
            throw FormulaFault.cell(.calculation)
        case let .scalar(scalar):
            result.append((scalar, false))
        case let .array(array):
            // Excel treats an array constant's members like referenced values: text and
            // booleans inside `{1,"x"}` are skipped by SUM rather than coerced.
            for value in array.values { result.append((value, true)) }
        case let .reference(reference):
            for part in reference.parts {
                var budget = scope.options.maxCellsPerAggregate
                scope.forEachPopulated(in: part) { _, scalar in
                    guard budget > 0 else { return }
                    budget -= 1
                    result.append((scalar, true))
                }
            }
        }
    }

    /// The numbers **one** argument contributes.
    ///
    /// Distinct from ``numbers(from:)`` and the distinction is load-bearing: `PERCENTILE`
    /// takes a data set *and* a fraction, so collecting "everything from argument 0" would
    /// fold the fraction into the data and quietly return the wrong percentile of the wrong
    /// set.
    func numbers(atArgument index: Int) throws -> [Double] {
        try numbers(in: try elements(from: index))
    }

    /// The numbers arguments `index...` contribute to a `SUM`-shaped aggregate.
    ///
    /// Errors propagate in argument order — the *first* error wins, which is why this collects
    /// rather than filters.
    func numbers(from index: Int) throws -> [Double] {
        try numbers(in: try allElements(from: index))
    }

    private func numbers(in elements: [(value: ScalarValue, viaReference: Bool)]) throws -> [Double] {
        var result: [Double] = []
        for element in elements {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            if element.viaReference {
                if case let .number(value) = element.value { result.append(value) }
            } else {
                result.append(try FunctionCallSite.number(from: element.value, dateSystem: scope.options.dateSystem))
            }
        }
        return result
    }

    // MARK: - Lambdas

    /// Argument `index` as a `LAMBDA`. `#VALUE!` for anything else, which is what Excel gives
    /// for `BYROW(A1:A3, 5)`.
    func lambda(_ index: Int) throws -> LambdaValue {
        guard index < arguments.count, let value = arguments[index].lambdaValue else {
            throw FormulaFault.cell(.wrongType)
        }
        return value
    }

    /// Calls a `LAMBDA` with the given arguments, in the environment it captured.
    func apply(_ lambda: LambdaValue, _ values: [FormulaValue]) throws -> FormulaValue {
        try scope.applyLambda(lambda, arguments: values, origin: origin)
    }

    /// Calls a `LAMBDA` and reduces its result to one scalar, which is what every helper in
    /// the `BYROW`/`MAP` family needs from it.
    func applyToScalar(_ lambda: LambdaValue, _ values: [FormulaValue]) throws -> ScalarValue {
        try FunctionCallSite.reduce(try apply(lambda, values), at: origin, scope: scope)
    }

    // MARK: - Aggregation

    /// Raises `#DIV/0!` when an aggregate had nothing to work with, which is what `AVERAGE`
    /// of an empty range gives.
    func requireNonEmpty(_ values: [Double]) throws -> [Double] {
        guard !values.isEmpty else { throw FormulaFault.cell(.divideByZero) }
        return values
    }
}
