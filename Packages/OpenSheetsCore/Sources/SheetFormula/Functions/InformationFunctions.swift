import Foundation
import SheetModel

/// The `IS…` predicates and the reference-shape functions.
///
/// Almost everything here declares `propagatesErrors: false`, because these are precisely the
/// functions that have to *see* an error rather than return it. `ISERROR(1/0)` is `TRUE`; if
/// the evaluator returned `#DIV/0!` before the call it would be `#DIV/0!`, and the one
/// function whose job is to catch errors would be the one function that cannot.
enum InformationFunctions {
    static var signatures: [FunctionSignature] { predicates + shape }

    private static let predicates: [FunctionSignature] = [
        FunctionSignature("ISBLANK", 1, 1, propagatesErrors: false) { call in
            if case .blank = try call.scalar(0) { return .boolean(true) }
            return .boolean(false)
        },
        FunctionSignature("ISNUMBER", 1, 1, propagatesErrors: false) { call in
            if case .number = try call.scalar(0) { return .boolean(true) }
            return .boolean(false)
        },
        FunctionSignature("ISTEXT", 1, 1, propagatesErrors: false) { call in
            if case .text = try call.scalar(0) { return .boolean(true) }
            return .boolean(false)
        },
        FunctionSignature("ISNONTEXT", 1, 1, propagatesErrors: false) { call in
            if case .text = try call.scalar(0) { return .boolean(false) }
            return .boolean(true)
        },
        FunctionSignature("ISLOGICAL", 1, 1, propagatesErrors: false) { call in
            if case .boolean = try call.scalar(0) { return .boolean(true) }
            return .boolean(false)
        },
        FunctionSignature("ISERROR", 1, 1, propagatesErrors: false) { call in
            .boolean(try call.scalar(0).isError)
        },
        FunctionSignature("ISERR", 1, 1, propagatesErrors: false) { call in
            // Everything except `#N/A` — the point of the distinction is that a lookup that
            // found nothing is not a broken formula.
            let value = try call.scalar(0)
            return .boolean(value.isError && value.errorValue != .notAvailable)
        },
        FunctionSignature("ISNA", 1, 1, propagatesErrors: false) { call in
            .boolean(try call.scalar(0).errorValue == .notAvailable)
        },
        FunctionSignature("ISFORMULA", 1, 1, propagatesErrors: false) { call in
            guard let cell = try call.reference(0).singleCell else { throw FormulaFault.cell(.wrongType) }
            return .boolean(call.scope.cell(at: cell)?.isFormula ?? false)
        },
        FunctionSignature("ISREF", 1, 1, propagatesErrors: false) { call in
            guard call.count > 0, case .reference = call.arguments[0] else { return .boolean(false) }
            return .boolean(true)
        },
        FunctionSignature("ISEVEN", 1, 1) { call in
            .boolean(Int(try call.number(0).rounded(.towardZero)).isMultiple(of: 2))
        },
        FunctionSignature("ISODD", 1, 1) { call in
            .boolean(!Int(try call.number(0).rounded(.towardZero)).isMultiple(of: 2))
        },
        FunctionSignature("NA", 0, 0) { _ in .error(.notAvailable) },
        FunctionSignature("N", 1, 1, propagatesErrors: false) { call in
            switch try call.scalar(0) {
            case let .number(value): return .number(value)
            case let .boolean(flag): return .number(flag ? 1 : 0)
            case let .error(error): return .error(error)
            case .text, .blank: return .number(0)
            }
        },
        FunctionSignature("T", 1, 1, propagatesErrors: false) { call in
            switch try call.scalar(0) {
            case let .text(value): return .text(value)
            case let .error(error): return .error(error)
            default: return .text("")
            }
        },
        FunctionSignature("TYPE", 1, 1, propagatesErrors: false) { call in
            guard call.count > 0 else { throw FormulaFault.cell(.wrongType) }
            if case .array = call.arguments[0] { return .number(64) }
            switch try call.scalar(0) {
            case .number, .blank: return .number(1)
            case .text: return .number(2)
            case .boolean: return .number(4)
            case .error: return .number(16)
            }
        },
        FunctionSignature("ERROR.TYPE", 1, 1, propagatesErrors: false) { call in
            guard let error = try call.scalar(0).errorValue else { throw FormulaFault.cell(.notAvailable) }
            return .number(Double(InformationFunctions.errorNumber(error)))
        },
    ]

    private static let shape: [FunctionSignature] = [
        FunctionSignature("ROW", 0, 1) { call in
            guard call.count > 0 else { return .number(Double(call.origin.ref.row + 1)) }
            return .number(Double(try call.reference(0).parts.first.map { $0.range.start.row + 1 } ?? 0))
        },
        FunctionSignature("COLUMN", 0, 1) { call in
            guard call.count > 0 else { return .number(Double(call.origin.ref.column + 1)) }
            return .number(Double(try call.reference(0).parts.first.map { $0.range.start.column + 1 } ?? 0))
        },
        FunctionSignature("ROWS", 1, 1) { call in .number(Double(try call.shape(0).rows)) },
        FunctionSignature("COLUMNS", 1, 1) { call in .number(Double(try call.shape(0).columns)) },
        FunctionSignature("SHEETS", 0, 0) { call in .number(Double(call.scope.workbook.sheets.count)) },
    ]

    /// Excel's numbering for `ERROR.TYPE`.
    static func errorNumber(_ error: CellError) -> Int {
        switch error {
        case .nullIntersection: 1
        case .divideByZero: 2
        case .wrongType: 3
        case .invalidReference: 4
        case .unknownName: 5
        case .invalidNumber: 6
        case .notAvailable: 7
        case .spill: 9
        case .calculation: 14
        // `#CIRCULAR` is ours, not Excel's, and has no number. `#VALUE!` is what it becomes
        // on the way into a file, so it reports as `#VALUE!` here too.
        case .circular: 3
        }
    }
}
