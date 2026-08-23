import Foundation
import SheetModel

/// The `LAMBDA` helpers: functions that take a function.
///
/// `LAMBDA` and `LET` themselves are **not** here. They are lazy forms the evaluator drives
/// directly, because both are about *names*: `LAMBDA(x, x*2)` must not evaluate `x`, and
/// `LET(n, 1, n+1)` must bind `n` before evaluating `n+1`. Anything that evaluated its
/// arguments first would see `#NAME?` on a formula Excel accepts. See
/// `FormulaEvaluator.pushCall`.
///
/// What lives here is the family that receives an already-built ``LambdaValue`` and applies it:
/// `BYROW`, `BYCOL`, `MAP`, `REDUCE`, `SCAN`, `MAKEARRAY`. All of them go through
/// ``FunctionCallSite/apply(_:_:)``, which is the single place lambda application is bounded —
/// `REDUCE` over a whole column applies a lambda a million times, and every one of those is a
/// re-entry into the evaluator.
enum LambdaFunctions {
    static var signatures: [FunctionSignature] { [
        FunctionSignature("BYROW", 2, 2, prefixed: true) { call in
            let source = try call.table(0)
            let body = try call.lambda(1)
            let results = try source.rowsOfValues.map { row in
                try call.applyToScalar(body, [.array(ValueArray(row: row))])
            }
            return .array(ValueArray(column: results))
        },
        FunctionSignature("BYCOL", 2, 2, prefixed: true) { call in
            let source = try call.table(0)
            let body = try call.lambda(1)
            let results = try source.columnsOfValues.map { column in
                try call.applyToScalar(body, [.array(ValueArray(column: column))])
            }
            return .array(ValueArray(row: results))
        },
        FunctionSignature("MAP", 2, .max, prefixed: true) { call in
            let body = try call.lambda(call.count - 1)
            var inputs: [ValueArray] = []
            for index in 0 ..< (call.count - 1) { inputs.append(try call.table(index)) }
            guard let first = inputs.first else { throw FormulaFault.cell(.wrongType) }
            // Excel requires every input to be the same shape; a mismatch is `#VALUE!` rather
            // than a broadcast, because `MAP` pairs elements positionally.
            guard inputs.allSatisfy({ $0.rowCount == first.rowCount && $0.columnCount == first.columnCount })
            else { throw FormulaFault.cell(.wrongType) }
            var values: [ScalarValue] = []
            values.reserveCapacity(first.count)
            for position in 0 ..< first.count {
                let arguments = inputs.map { FormulaValue.scalar($0.values[position]) }
                values.append(try call.applyToScalar(body, arguments))
            }
            return .array(ValueArray(
                rowCount: first.rowCount, columnCount: first.columnCount, values: values
            ))
        },
        FunctionSignature("REDUCE", 3, 3, prefixed: true) { call in
            let source = try call.table(1)
            let body = try call.lambda(2)
            var accumulator = call.arguments[0]
            for element in source.values {
                accumulator = .scalar(try call.applyToScalar(body, [accumulator, .scalar(element)]))
            }
            return accumulator
        },
        FunctionSignature("SCAN", 3, 3, prefixed: true) { call in
            let source = try call.table(1)
            let body = try call.lambda(2)
            var accumulator = call.arguments[0]
            var values: [ScalarValue] = []
            values.reserveCapacity(source.count)
            for element in source.values {
                let next = try call.applyToScalar(body, [accumulator, .scalar(element)])
                values.append(next)
                accumulator = .scalar(next)
            }
            return .array(ValueArray(
                rowCount: source.rowCount, columnCount: source.columnCount, values: values
            ))
        },
        FunctionSignature("MAKEARRAY", 3, 3, prefixed: true) { call in
            let size = try ArrayFunctions.checkedSize(
                rows: try call.integer(0), columns: try call.integer(1)
            )
            let body = try call.lambda(2)
            var values: [ScalarValue] = []
            values.reserveCapacity(size.rows * size.columns)
            for row in 1 ... size.rows {
                for column in 1 ... size.columns {
                    values.append(try call.applyToScalar(
                        body, [.number(Double(row)), .number(Double(column))]
                    ))
                }
            }
            return .array(ValueArray(
                rowCount: size.rows, columnCount: size.columns, values: values
            ))
        },
    ] }
}
