import Foundation
import SheetModel

/// The `…IF` and `…IFS` family.
///
/// Two argument orders, which is Excel's doing rather than ours: the singular forms put the
/// tested range first (`SUMIF(range, criteria, [sumRange])`), the plural forms put the summed
/// range first (`SUMIFS(sumRange, range1, criteria1, …)`). Getting them the wrong way round
/// produces a number, not an error, which is exactly the kind of silent wrong answer that has
/// to be caught by tests rather than by reading.
enum ConditionalFunctions {
    static var signatures: [FunctionSignature] { [
        FunctionSignature("COUNTIF", 2, 2) { call in
            let matches = try ConditionalFunctions.singularMatches(call)
            return .number(Double(matches.count))
        },
        FunctionSignature("SUMIF", 2, 3) { call in
            let source = try ConditionalFunctions.singularTarget(call, at: 2)
            return .number(ExcelNumber.sum(try ConditionalFunctions.pick(
                try ConditionalFunctions.singularMatches(call), from: source
            )))
        },
        FunctionSignature("AVERAGEIF", 2, 3) { call in
            let source = try ConditionalFunctions.singularTarget(call, at: 2)
            let values = try ConditionalFunctions.pick(try ConditionalFunctions.singularMatches(call), from: source)
            guard !values.isEmpty else { throw FormulaFault.cell(.divideByZero) }
            return .number(ExcelNumber.sum(values) / Double(values.count))
        },
        FunctionSignature("COUNTIFS", 2, .max) { call in
            .number(Double(try ConditionalFunctions.pluralMatches(call, from: 0).count))
        },
        FunctionSignature("SUMIFS", 3, .max) { call in
            let matches = try ConditionalFunctions.pluralMatches(call, from: 1)
            return .number(ExcelNumber.sum(try ConditionalFunctions.pick(matches, from: try call.table(0))))
        },
        FunctionSignature("AVERAGEIFS", 3, .max) { call in
            let matches = try ConditionalFunctions.pluralMatches(call, from: 1)
            let values = try ConditionalFunctions.pick(matches, from: try call.table(0))
            guard !values.isEmpty else { throw FormulaFault.cell(.divideByZero) }
            return .number(ExcelNumber.sum(values) / Double(values.count))
        },
        FunctionSignature("MAXIFS", 3, .max, prefixed: true) { call in
            let matches = try ConditionalFunctions.pluralMatches(call, from: 1)
            return .number(try ConditionalFunctions.pick(matches, from: try call.table(0)).max() ?? 0)
        },
        FunctionSignature("MINIFS", 3, .max, prefixed: true) { call in
            let matches = try ConditionalFunctions.pluralMatches(call, from: 1)
            return .number(try ConditionalFunctions.pick(matches, from: try call.table(0)).min() ?? 0)
        },
    ] }

    // MARK: - Singular forms

    private static func singularMatches(_ call: FunctionCallSite) throws -> [Int] {
        let table = try call.table(0)
        let criterion = Criterion(try call.scalar(1), dateSystem: call.scope.options.dateSystem)
        return (0 ..< table.count).filter { criterion.matches(table.values[$0]) }
    }

    /// The range a singular form actually reads from — the third argument when present,
    /// otherwise the tested range itself.
    ///
    /// Excel re-shapes a mismatched third argument to the first argument's dimensions,
    /// anchored at its top-left. `SUMIF(A1:A10,">0",B1)` sums `B1:B10`.
    private static func singularTarget(_ call: FunctionCallSite, at index: Int) throws -> ValueArray {
        let tested = try call.table(0)
        guard call.count > index, call.isPresent(index) else { return tested }
        guard case let .reference(reference) = call.arguments[index], let part = reference.singleRange else {
            return try call.table(index)
        }
        let reshaped = CellRange(
            rows: part.range.start.row ... min(part.range.start.row + tested.rowCount - 1, Limits.maxRow),
            columns: part.range.start.column ... min(part.range.start.column + tested.columnCount - 1, Limits.maxColumn)
        )
        return try FunctionCallSite.table(
            .reference(ReferenceValue(SheetRange(sheet: part.sheet, range: reshaped))), scope: call.scope
        )
    }

    // MARK: - Plural forms

    /// Positions satisfying every `(range, criteria)` pair starting at `start`.
    private static func pluralMatches(_ call: FunctionCallSite, from start: Int) throws -> [Int] {
        var pairs: [(table: ValueArray, criterion: Criterion)] = []
        var index = start
        while index + 1 < call.count {
            pairs.append((
                try call.table(index),
                Criterion(try call.scalar(index + 1), dateSystem: call.scope.options.dateSystem)
            ))
            index += 2
        }
        guard let first = pairs.first else { throw FormulaFault.cell(.wrongType) }
        guard pairs.allSatisfy({ $0.table.rowCount == first.table.rowCount
                && $0.table.columnCount == first.table.columnCount })
        else { throw FormulaFault.cell(.wrongType) }

        return (0 ..< first.table.count).filter { position in
            pairs.allSatisfy { $0.criterion.matches($0.table.values[position]) }
        }
    }

    /// The numbers at `positions` in `source`, skipping anything that is not a number and
    /// propagating the first error.
    private static func pick(_ positions: [Int], from source: ValueArray) throws -> [Double] {
        var result: [Double] = []
        for position in positions where position < source.count {
            if let error = source.values[position].errorValue { throw FormulaFault.cell(error) }
            if case let .number(value) = source.values[position] { result.append(value) }
        }
        return result
    }
}
