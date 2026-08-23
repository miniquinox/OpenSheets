import Foundation
import SheetModel

/// Boolean logic.
///
/// `AND` and `OR` are **eager** — Excel evaluates every argument, so `=OR(TRUE,1/0)` is
/// `#DIV/0!`, not `TRUE`. Only `IF`, `IFS`, `SWITCH`, `CHOOSE`, `IFERROR` and `IFNA` skip
/// arguments, and those are driven by the evaluator rather than living here.
enum LogicalFunctions {
    static var signatures: [FunctionSignature] { [
        FunctionSignature("TRUE", 0, 0) { _ in .boolean(true) },
        FunctionSignature("FALSE", 0, 0) { _ in .boolean(false) },
        FunctionSignature("NOT", 1, 1) { call in
            switch Coercion.boolean(try call.scalar(0)) {
            case let .success(flag): return .boolean(!flag)
            case let .failure(error): throw FormulaFault.cell(error)
            }
        },
        FunctionSignature("AND", 1, .max) { call in
            .boolean(try LogicalFunctions.fold(call) { $0 && $1 })
        },
        FunctionSignature("OR", 1, .max) { call in
            .boolean(try LogicalFunctions.fold(call) { $0 || $1 })
        },
        FunctionSignature("XOR", 1, .max) { call in
            let flags = try LogicalFunctions.flags(call)
            guard !flags.isEmpty else { throw FormulaFault.cell(.wrongType) }
            return .boolean(flags.filter { $0 }.count % 2 == 1)
        },
        // Driven by the evaluator; the signature exists for arity checking and for the
        // dependency graph to know the name is real.
        FunctionSignature(lazy: "IF", 2, 3),
        FunctionSignature(lazy: "IFERROR", 2, 2),
        FunctionSignature(lazy: "IFNA", 2, 2, prefixed: true),
        FunctionSignature(lazy: "IFS", 2, 254, prefixed: true),
        FunctionSignature(lazy: "SWITCH", 3, 254, prefixed: true),
        FunctionSignature(lazy: "CHOOSE", 2, 254),
    ] }

    /// The booleans an argument list contributes.
    ///
    /// Text and blanks reached through a reference are skipped; a direct text argument is
    /// `#VALUE!`. Same split as the numeric aggregates, same reason: a stray label in a column
    /// must not silently change the answer.
    private static func flags(_ call: FunctionCallSite) throws -> [Bool] {
        var result: [Bool] = []
        for element in try call.allElements(from: 0) {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            switch element.value {
            case let .boolean(flag):
                result.append(flag)
            case let .number(value):
                result.append(value != 0)
            case .blank:
                // An omitted argument contributes nothing rather than failing: `AND(TRUE,)`
                // is `TRUE` in Excel.
                continue
            case .text:
                guard element.viaReference else { throw FormulaFault.cell(.wrongType) }
            case .error:
                break
            }
        }
        return result
    }

    private static func fold(_ call: FunctionCallSite, _ combine: (Bool, Bool) -> Bool) throws -> Bool {
        let values = try flags(call)
        guard let first = values.first else { throw FormulaFault.cell(.wrongType) }
        return values.dropFirst().reduce(first, combine)
    }
}
