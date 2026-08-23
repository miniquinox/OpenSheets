import Foundation
import SheetModel

/// Evaluates one parsed formula against one workbook snapshot.
///
/// **Explicit stack, no recursion.** Two stacks — one of pending work, one of finished values —
/// and a loop. A formula that is 4,000 additions long, or a defined name that expands into
/// another defined name, costs heap rather than stack, so there is no input that can overflow.
/// The cell-level recalc walk in ``FormulaEngine`` is iterative for the same reason; between
/// them, "never hang, never stack-overflow" is a property of the design rather than a hope
/// about input sizes.
struct FormulaEvaluator {
    /// Iterations one formula may take before we call it pathological. Generous — a 8,192-byte
    /// formula cannot legitimately produce more than a few thousand steps — and finite, which
    /// is the point.
    static let maximumSteps = 1_000_000

    /// How deep defined names may expand into other defined names.
    static let maximumNameDepth = 16

    let scope: EvaluationScope
    let origin: SheetCell

    private enum Work {
        case eval(FormulaExpression)
        case unary(FormulaOperator)
        case percent
        case binary(FormulaOperator)
        case rangeOperator
        case intersection
        case union(Int)
        case call(FunctionCall)
        case selectBranch(FunctionCall)
        case catchError(FunctionCall, onlyNotAvailable: Bool)
        case nextCondition(FunctionCall, Int)
        case beginSwitch(FunctionCall)
        case compareSwitch(FunctionCall, Int)
        case selectChoice(FunctionCall)
        case popNameDepth
    }

    /// Evaluates `expression`, or throws ``FormulaFault``.
    func evaluate(_ expression: FormulaExpression) throws -> FormulaValue {
        var work: [Work] = [.eval(expression)]
        var values: [FormulaValue] = []
        var selectors: [ScalarValue] = []
        var nameDepth = 0
        var steps = 0

        while let step = work.popLast() {
            steps += 1
            guard steps <= FormulaEvaluator.maximumSteps else { throw FormulaFault.cell(.invalidNumber) }

            do {
                try apply(
                    step, work: &work, values: &values, selectors: &selectors, nameDepth: &nameDepth
                )
            } catch let fault as FormulaFault {
                // **An Excel error is a value, not an exception.** `1/0` inside `ISERROR` has to
                // arrive as `#DIV/0!` for `ISERROR` to see it, so a failed step pushes the error
                // where its result would have gone rather than unwinding. Every step's stack
                // effect is "pop n, push one", and that holds on this path too.
                //
                // `.unsupported` is the opposite case and does unwind: it is not an answer.
                guard case let .cell(error) = fault else { throw fault }
                values.append(.error(error))
            }
        }
        return try pop(&values)
    }

    private func apply(
        _ step: Work,
        work: inout [Work],
        values: inout [FormulaValue],
        selectors: inout [ScalarValue],
        nameDepth: inout Int
    ) throws {
        switch step {
            case let .eval(node):
                try push(node, into: &work, values: &values, nameDepth: &nameDepth)
            case .popNameDepth:
                nameDepth -= 1
            case let .unary(symbol):
                let operand = try pop(&values)
                values.append(try applyUnary(symbol, operand))
            case .percent:
                let operand = try reduce(try pop(&values))
                values.append(.number(try FunctionCallSite.number(
                    from: operand, dateSystem: scope.options.dateSystem
                ) / 100))
            case let .binary(symbol):
                let right = try pop(&values)
                let left = try pop(&values)
                values.append(try applyBinary(symbol, left, right))
            case .rangeOperator:
                let right = try pop(&values)
                let left = try pop(&values)
                values.append(try applyRangeOperator(left, right))
            case .intersection:
                let right = try pop(&values)
                let left = try pop(&values)
                values.append(try applyIntersection(left, right))
            case let .union(count):
                // Remove first, then validate: a step that throws must still have consumed its
                // operands, or the error value pushed by the catch above lands on a stack that
                // is one deep too many.
                let operands = Array(values.suffix(count))
                values.removeLast(count)
                var parts: [SheetRange] = []
                for value in operands {
                    guard case let .reference(reference) = value else { throw FormulaFault.cell(.wrongType) }
                    parts += reference.parts
                }
                values.append(.reference(ReferenceValue(parts)))
            case let .call(function):
                let arguments = Array(values.suffix(function.arguments.count))
                values.removeLast(function.arguments.count)
                values.append(try invoke(function, arguments: arguments))
            case let .selectBranch(function):
                try selectBranch(function, work: &work, values: &values)
            case let .catchError(function, onlyNotAvailable):
                try catchError(function, onlyNotAvailable: onlyNotAvailable, work: &work, values: &values)
            case let .nextCondition(function, index):
                try nextCondition(function, index, work: &work, values: &values)
            case let .beginSwitch(function):
                selectors.append(try reduce(try pop(&values)))
                work.append(.compareSwitch(function, 1))
                work.append(.eval(function.arguments[1]))
            case let .compareSwitch(function, index):
                try compareSwitch(function, index, work: &work, values: &values, selectors: &selectors)
            case let .selectChoice(function):
                let index = try FunctionCallSite.number(
                    from: try reduce(try pop(&values)), dateSystem: scope.options.dateSystem
                )
                let position = Int(index.rounded(.towardZero))
                guard position >= 1, position < function.arguments.count else {
                    throw FormulaFault.cell(.wrongType)
                }
                work.append(.eval(function.arguments[position]))
        }
    }

    // MARK: - Dispatch

    private func push(
        _ node: FormulaExpression, into work: inout [Work], values: inout [FormulaValue], nameDepth: inout Int
    ) throws {
        switch node {
        case let .number(value):
            values.append(.number(value))
        case let .string(value):
            values.append(.text(value))
        case let .boolean(value):
            values.append(.boolean(value))
        case let .errorLiteral(value):
            values.append(.error(value))
        case .missing:
            values.append(.blank)
        case let .array(literal):
            values.append(.array(literal.valueArray))
        case let .unsupported(text):
            throw FormulaFault.unsupported(.syntax(text))
        case let .reference(reference):
            values.append(try resolve(reference))
        case let .name(name):
            try pushName(name, into: &work, values: &values, nameDepth: &nameDepth)
        case let .group(inner):
            work.append(.eval(inner))
        case let .unary(symbol, operand):
            work.append(.unary(symbol))
            work.append(.eval(operand))
        case let .percent(operand):
            work.append(.percent)
            work.append(.eval(operand))
        case let .binary(symbol, lhs, rhs):
            work.append(.binary(symbol))
            work.append(.eval(rhs))
            work.append(.eval(lhs))
        case let .rangeOperator(lhs, rhs):
            work.append(.rangeOperator)
            work.append(.eval(rhs))
            work.append(.eval(lhs))
        case let .intersection(lhs, rhs):
            work.append(.intersection)
            work.append(.eval(rhs))
            work.append(.eval(lhs))
        case let .union(parts):
            work.append(.union(parts.count))
            for part in parts.reversed() { work.append(.eval(part)) }
        case let .call(function):
            try pushCall(function, into: &work)
        }
    }

    private func pushCall(_ function: FunctionCall, into work: inout [Work]) throws {
        guard let signature = FunctionCatalog.signature(for: function.name) else {
            if FunctionCatalog.isKnownButUnimplemented(function.name, wasPrefixed: function.wasPrefixed) {
                throw FormulaFault.unsupported(.function(function.name))
            }
            throw FormulaFault.cell(.unknownName)
        }
        guard signature.accepts(argumentCount: function.arguments.count) else {
            throw FormulaFault.cell(.wrongType)
        }
        guard case .lazy = signature.body else {
            work.append(.call(function))
            for argument in function.arguments.reversed() { work.append(.eval(argument)) }
            return
        }
        switch function.name {
        case "IF":
            work.append(.selectBranch(function))
            work.append(.eval(function.arguments[0]))
        case "IFERROR", "IFNA":
            work.append(.catchError(function, onlyNotAvailable: function.name == "IFNA"))
            work.append(.eval(function.arguments[0]))
        case "IFS":
            work.append(.nextCondition(function, 0))
            work.append(.eval(function.arguments[0]))
        case "SWITCH":
            work.append(.beginSwitch(function))
            work.append(.eval(function.arguments[0]))
        default:
            work.append(.selectChoice(function))
            work.append(.eval(function.arguments[0]))
        }
    }

    // MARK: - Lazy functions

    private func selectBranch(_ function: FunctionCall, work: inout [Work], values: inout [FormulaValue]) throws {
        let condition = try reduce(try pop(&values))
        let flag: Bool
        switch Coercion.boolean(condition) {
        case let .success(value): flag = value
        case let .failure(error): throw FormulaFault.cell(error)
        }
        let index = flag ? 1 : 2
        guard index < function.arguments.count else {
            values.append(.boolean(false))
            return
        }
        // `IF(A1,,5)` with a true condition is `0` in Excel, not blank.
        if case .missing = function.arguments[index] {
            values.append(.number(0))
            return
        }
        work.append(.eval(function.arguments[index]))
    }

    private func catchError(
        _ function: FunctionCall, onlyNotAvailable: Bool, work: inout [Work], values: inout [FormulaValue]
    ) throws {
        let candidate = values.popLast() ?? .blank
        var error: CellError?
        do {
            error = try reduce(candidate).errorValue
        } catch let fault as FormulaFault {
            // A `#VALUE!` raised while reducing the guarded expression is exactly the kind of
            // failure IFERROR exists to swallow. An *unsupported* one is not, and rethrows.
            guard case let .cell(value) = fault else { throw fault }
            error = value
        }
        guard let error, !onlyNotAvailable || error == .notAvailable else {
            values.append(candidate)
            return
        }
        work.append(.eval(function.arguments[1]))
    }

    private func nextCondition(
        _ function: FunctionCall, _ index: Int, work: inout [Work], values: inout [FormulaValue]
    ) throws {
        let condition = try reduce(try pop(&values))
        switch Coercion.boolean(condition) {
        case let .success(flag) where flag:
            guard index + 1 < function.arguments.count else { throw FormulaFault.cell(.notAvailable) }
            work.append(.eval(function.arguments[index + 1]))
        case .success:
            let next = index + 2
            guard next < function.arguments.count else { throw FormulaFault.cell(.notAvailable) }
            work.append(.nextCondition(function, next))
            work.append(.eval(function.arguments[next]))
        case let .failure(error):
            throw FormulaFault.cell(error)
        }
    }

    private func compareSwitch(
        _ function: FunctionCall, _ index: Int,
        work: inout [Work], values: inout [FormulaValue], selectors: inout [ScalarValue]
    ) throws {
        let candidate = try reduce(try pop(&values))
        guard let selector = selectors.last else { throw FormulaFault.cell(.wrongType) }
        // An argument with nothing after it is the default value, and it has already been
        // evaluated as if it were a case label.
        guard index + 1 < function.arguments.count else {
            selectors.removeLast()
            values.append(.scalar(candidate))
            return
        }
        guard case let .success(equal) = Coercion.equals(selector, candidate) else {
            throw FormulaFault.cell(.wrongType)
        }
        if equal {
            selectors.removeLast()
            work.append(.eval(function.arguments[index + 1]))
            return
        }
        let next = index + 2
        guard next < function.arguments.count else {
            selectors.removeLast()
            throw FormulaFault.cell(.notAvailable)
        }
        work.append(.compareSwitch(function, next))
        work.append(.eval(function.arguments[next]))
    }

    // MARK: - Names

    private func pushName(
        _ name: NameReference, into work: inout [Work], values: inout [FormulaValue], nameDepth: inout Int
    ) throws {
        if let qualifier = name.qualifier, qualifier.isExternal {
            throw FormulaFault.unsupported(.externalWorkbook(name.text))
        }
        var scopeID: SheetID? = origin.sheet
        if let qualifier = name.qualifier {
            guard let resolved = scope.sheetID(named: qualifier.name) else {
                throw FormulaFault.cell(.invalidReference)
            }
            scopeID = resolved
        }
        guard let defined = scope.workbook.definedName(name.name, scope: scopeID)
            ?? scope.workbook.definedName(name.name)
        else { throw FormulaFault.cell(.unknownName) }

        if let target = defined.target {
            values.append(.reference(ReferenceValue(SheetRange(
                sheet: target.sheet ?? origin.sheet, range: target.range
            ))))
            return
        }
        guard nameDepth < FormulaEvaluator.maximumNameDepth else { throw FormulaFault.cell(.circular) }
        let body = defined.formula.hasPrefix("=") ? String(defined.formula.dropFirst()) : defined.formula
        let expression: FormulaExpression
        do {
            expression = try FormulaParser.parse(body, anchor: origin.ref, grammar: scope.options.grammar)
        } catch {
            throw FormulaFault.cell(.unknownName)
        }
        // `.popNameDepth` sits *below* the expansion on the work stack, so it is reached only
        // once the whole expansion has finished — the iterative equivalent of a `defer`.
        nameDepth += 1
        work.append(.popNameDepth)
        work.append(.eval(expression))
    }

    // MARK: - Operators

    private func applyUnary(_ symbol: FormulaOperator, _ operand: FormulaValue) throws -> FormulaValue {
        let scalar = try reduce(operand)
        if let error = scalar.errorValue { throw FormulaFault.cell(error) }
        // Unary plus is a genuine no-op in Excel: `=+"a"` is `"a"`, not `#VALUE!`.
        guard symbol == .subtract else { return .scalar(scalar) }
        return .number(-(try FunctionCallSite.number(from: scalar, dateSystem: scope.options.dateSystem)))
    }

    private func applyBinary(
        _ symbol: FormulaOperator, _ left: FormulaValue, _ right: FormulaValue
    ) throws -> FormulaValue {
        let lhs = try reduce(left)
        if let error = lhs.errorValue { throw FormulaFault.cell(error) }
        let rhs = try reduce(right)
        if let error = rhs.errorValue { throw FormulaFault.cell(error) }

        switch symbol {
        case .concat:
            let a = try text(lhs)
            let b = try text(rhs)
            return try .text(TextFunctions.checkLength(a + b))
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual:
            guard case let .success(order) = Coercion.compare(lhs, rhs) else {
                throw FormulaFault.cell(.wrongType)
            }
            switch symbol {
            case .equal: return .boolean(order == 0)
            case .notEqual: return .boolean(order != 0)
            case .less: return .boolean(order < 0)
            case .lessOrEqual: return .boolean(order <= 0)
            case .greater: return .boolean(order > 0)
            default: return .boolean(order >= 0)
            }
        default:
            let a = try FunctionCallSite.number(from: lhs, dateSystem: scope.options.dateSystem)
            let b = try FunctionCallSite.number(from: rhs, dateSystem: scope.options.dateSystem)
            return try .scalar(arithmetic(symbol, a, b))
        }
    }

    private func arithmetic(_ symbol: FormulaOperator, _ lhs: Double, _ rhs: Double) throws -> ScalarValue {
        switch symbol {
        case .add: return ExcelNumber.checked(ExcelNumber.add(lhs, rhs))
        case .subtract: return ExcelNumber.checked(ExcelNumber.subtract(lhs, rhs))
        case .multiply: return ExcelNumber.checked(lhs * rhs)
        case .divide:
            guard rhs != 0 else { throw FormulaFault.cell(.divideByZero) }
            return ExcelNumber.checked(lhs / rhs)
        case .power: return try MathFunctions.power(lhs, rhs)
        default: throw FormulaFault.cell(.wrongType)
        }
    }

    private func applyRangeOperator(_ left: FormulaValue, _ right: FormulaValue) throws -> FormulaValue {
        guard case let .reference(a) = left, case let .reference(b) = right,
              let first = a.singleRange, let second = b.singleRange, first.sheet == second.sheet
        else { throw FormulaFault.cell(.wrongType) }
        return .reference(ReferenceValue(SheetRange(sheet: first.sheet, range: first.range.union(second.range))))
    }

    private func applyIntersection(_ left: FormulaValue, _ right: FormulaValue) throws -> FormulaValue {
        guard case let .reference(a) = left, case let .reference(b) = right,
              let first = a.singleRange, let second = b.singleRange, first.sheet == second.sheet
        else { throw FormulaFault.cell(.wrongType) }
        guard let overlap = first.range.intersection(second.range) else {
            throw FormulaFault.cell(.nullIntersection)
        }
        return .reference(ReferenceValue(SheetRange(sheet: first.sheet, range: overlap)))
    }

    // MARK: - Calls

    private func invoke(_ function: FunctionCall, arguments: [FormulaValue]) throws -> FormulaValue {
        guard let signature = FunctionCatalog.signature(for: function.name),
              case let .eager(body) = signature.body
        else { throw FormulaFault.cell(.unknownName) }

        if signature.propagatesErrors {
            // The *first* error in argument order wins, which is why this scans rather than
            // reduces: `=SUM(1/0, NA())` is `#DIV/0!`, not `#N/A`.
            for argument in arguments {
                if let error = argument.errorValue { throw FormulaFault.cell(error) }
            }
        }
        return try body(FunctionCallSite(
            arguments: arguments, scope: scope, origin: origin, name: function.name
        ))
    }

    // MARK: - Helpers

    private func resolve(_ reference: FormulaReference) throws -> FormulaValue {
        if let qualifier = reference.qualifier {
            if qualifier.isExternal { throw FormulaFault.unsupported(.externalWorkbook(reference.a1Text)) }
            if qualifier.isThreeDimensional {
                throw FormulaFault.unsupported(.threeDimensionalReference(reference.a1Text))
            }
        }
        guard !reference.isDeleted else { throw FormulaFault.cell(.invalidReference) }
        guard reference.isOnSheet else { throw FormulaFault.cell(.invalidReference) }
        var sheet = origin.sheet
        if let name = reference.qualifier?.name {
            guard let resolved = scope.sheetID(named: name) else { throw FormulaFault.cell(.invalidReference) }
            sheet = resolved
        }
        return .reference(ReferenceValue(SheetRange(sheet: sheet, range: reference.range)))
    }

    private func reduce(_ value: FormulaValue) throws -> ScalarValue {
        try FunctionCallSite.reduce(value, at: origin, scope: scope)
    }

    private func text(_ value: ScalarValue) throws -> String {
        switch Coercion.text(value) {
        case let .success(result): return result
        case let .failure(error): throw FormulaFault.cell(error)
        }
    }

    private func pop(_ values: inout [FormulaValue]) throws -> FormulaValue {
        guard let value = values.popLast() else { throw FormulaFault.cell(.wrongType) }
        return value
    }
}
