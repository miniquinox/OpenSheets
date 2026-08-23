import Foundation
import SheetModel

/// The module's front door for anything that is "text in, text out".
///
/// Everything here is pure and needs no workbook: parse, re-spell, convert between A1 and
/// R1C1, validate before committing. A8's edit path and A9's MCP surface both live on these
/// four operations; evaluation is a separate concern in ``FormulaEngine``.
public enum FormulaSyntax {
    /// Parses formula text. `source` must **not** include the leading `=`.
    public static func parse(
        _ source: String,
        style: ReferenceStyle = .a1,
        anchor: CellRef = .origin,
        grammar: FormulaGrammar = .default
    ) throws(SheetError) -> FormulaExpression {
        try FormulaParser.parse(source, style: style, anchor: anchor, grammar: grammar)
    }

    /// Writes a parsed formula back out.
    public static func write(_ expression: FormulaExpression, format: FormulaFormat = .display) -> String {
        FormulaWriter.write(expression, format: format)
    }

    /// Whether `source` parses, throwing the reason it does not.
    ///
    /// This is what PLAN.md §8 means by "formula parses before it is committed": the write API
    /// calls it, so a formula that would make the file unopenable is refused at the boundary
    /// rather than written and discovered later.
    @discardableResult
    public static func validate(
        _ source: String, anchor: CellRef = .origin, grammar: FormulaGrammar = .default
    ) throws(SheetError) -> FormulaExpression {
        let expression = try parse(source, anchor: anchor, grammar: grammar)
        try checkArity(expression, source: source)
        return expression
    }

    /// The spelling to write into a file: `_xlfn.` prefixes restored.
    public static func toStorage(_ source: String, anchor: CellRef = .origin) throws(SheetError) -> String {
        write(try parse(source, anchor: anchor), format: FormulaFormat(anchor: anchor, usesStoragePrefixes: true))
    }

    /// The spelling to show in the formula bar: `_xlfn.` prefixes stripped.
    public static func toDisplay(_ source: String, anchor: CellRef = .origin) throws(SheetError) -> String {
        write(try parse(source, anchor: anchor), format: FormulaFormat(anchor: anchor))
    }

    /// An A1 formula in R1C1 form, relative to the cell it lives in.
    public static func toR1C1(_ source: String, at anchor: CellRef) throws(SheetError) -> String {
        write(try parse(source, anchor: anchor), format: .r1c1(anchor: anchor))
    }

    /// An R1C1 formula in A1 form, relative to the cell it lives in.
    ///
    /// This is how a shared-formula group expands: the master's R1C1 text applied at each
    /// member's address gives that member's own A1 formula.
    public static func fromR1C1(_ source: String, at anchor: CellRef) throws(SheetError) -> String {
        write(
            try parse(source, style: .r1c1, anchor: anchor),
            format: FormulaFormat(anchor: anchor, usesStoragePrefixes: true)
        )
    }

    /// Whether the formula uses only syntax and functions we can evaluate.
    ///
    /// `false` does **not** mean the formula is broken — it means we would have to guess, and
    /// the cell should keep its cached value with ``CellFlags/unsupportedFormula`` set.
    public static func isEvaluable(_ expression: FormulaExpression) -> Bool {
        unsupportedReason(in: expression) == nil
    }

    /// Why a formula cannot be evaluated, or `nil` when it can.
    public static func unsupportedReason(in expression: FormulaExpression) -> UnsupportedReason? {
        var found: UnsupportedReason?
        expression.forEachNode { node in
            guard found == nil else { return }
            switch node {
            case let .unsupported(text):
                found = .syntax(text)
            case let .reference(reference):
                if let qualifier = reference.qualifier {
                    if qualifier.isExternal { found = .externalWorkbook(reference.a1Text) }
                    if qualifier.isThreeDimensional { found = .threeDimensionalReference(reference.a1Text) }
                }
            case let .name(name):
                if name.qualifier?.isExternal == true { found = .externalWorkbook(name.text) }
            case let .call(call):
                if FunctionCatalog.signature(for: call.name) == nil,
                   FunctionCatalog.isKnownButUnimplemented(call.name, wasPrefixed: call.wasPrefixed) {
                    found = .function(call.name)
                }
            default:
                break
            }
        }
        return found
    }

    /// Whether any function in the formula recomputes on every pass.
    public static func isVolatile(_ expression: FormulaExpression) -> Bool {
        var volatile = false
        expression.forEachNode { node in
            guard case let .call(call) = node else { return }
            if FunctionCatalog.signature(for: call.name)?.isVolatile == true { volatile = true }
        }
        return volatile
    }

    /// Every function name the formula calls, in no particular order.
    public static func functionNames(in expression: FormulaExpression) -> Set<String> {
        var names: Set<String> = []
        expression.forEachNode { node in
            if case let .call(call) = node { names.insert(call.name) }
        }
        return names
    }

    private static func checkArity(_ expression: FormulaExpression, source: String) throws(SheetError) {
        var failure: SheetError?
        expression.forEachNode { node in
            guard failure == nil, case let .call(call) = node else { return }
            guard let signature = FunctionCatalog.signature(for: call.name) else { return }
            guard !signature.accepts(argumentCount: call.arguments.count) else { return }
            let expectation = signature.maximumArguments == Int.max
                ? "at least \(signature.minimumArguments)"
                : "\(signature.minimumArguments) to \(signature.maximumArguments)"
            failure = SheetError.invalidFormula(
                text: source,
                position: nil,
                reason: "\(call.name) takes \(expectation) arguments, not \(call.arguments.count)"
            )
        }
        if let failure { throw failure }
    }
}
