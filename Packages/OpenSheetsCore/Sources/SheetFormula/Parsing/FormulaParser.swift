import Dispatch
import Foundation
import SheetModel

/// The two places Excel's operator precedence disagrees with ordinary mathematics.
///
/// **The rule for this project: where Excel and mathematical convention disagree, Excel wins.**
/// OpenSheets reads and writes real `.xlsx` files, so a workbook has to mean the same thing in
/// both applications. ``excel`` is therefore the default, and it is deliberately the *less*
/// mathematically defensible of the two:
///
/// - Unary minus binds **tighter** than `^`, so `=-2^2` is `4`. Microsoft documents this as a
///   deviation from standard maths.
/// - `^` associates **left to right**, so `=2^3^2` is `(2^3)^2 = 64`, not `512`.
///
/// If you are reading this because you think the default is a bug and are about to flip it:
/// please do not. Here is the failure that produces. A workbook contains `=-2^2`; Excel cached
/// `4`; we open it and render `4` from the cache, correctly. The user then edits an unrelated
/// precedent, we recalculate, and we write `-4` into their file — silently, with no way for
/// them to notice. That is a plausible-looking wrong number in a real file, which is the one
/// outcome this engine exists to refuse.
///
/// ``mathematical`` keeps the other reading available for a future preference, and both
/// settings are covered by the precedence suite so neither can rot.
public struct FormulaGrammar: Sendable, Hashable {
    /// `2^3^2` is `2^(3^2)` when true, `(2^3)^2` when false.
    public var powerIsRightAssociative: Bool
    /// `-2^2` is `(-2)^2` when true, `-(2^2)` when false.
    public var unaryMinusBindsTighterThanPower: Bool

    public init(powerIsRightAssociative: Bool, unaryMinusBindsTighterThanPower: Bool) {
        self.powerIsRightAssociative = powerIsRightAssociative
        self.unaryMinusBindsTighterThanPower = unaryMinusBindsTighterThanPower
    }

    /// Excel's reading. `-2^2 == 4`, `2^3^2 == 64`. **The default.**
    public static let excel = FormulaGrammar(
        powerIsRightAssociative: false, unaryMinusBindsTighterThanPower: true
    )

    /// The ordinary mathematical reading. `-2^2 == -4`, `2^3^2 == 512`.
    ///
    /// Opt-in only: a workbook evaluated this way disagrees with Excel about formulas Excel can
    /// also open. Useful for a future "strict maths" preference, and for making the divergence
    /// visible in tests rather than only in prose.
    public static let mathematical = FormulaGrammar(
        powerIsRightAssociative: true, unaryMinusBindsTighterThanPower: false
    )

    /// What every `grammar:` parameter in the module falls back to: ``excel``.
    public static let `default` = excel
}

/// Turns tokens into a ``FormulaExpression``.
///
/// Precedence climbing rather than a rule per level: the two knobs in ``FormulaGrammar`` are
/// then a change to two integers instead of a change to the shape of the grammar.
public struct FormulaParser: Sendable {
    /// How deeply the parser will recurse before giving up.
    ///
    /// Separate from ``Limits/maxFormulaNestingDepth`` (64), which counts *function* nesting
    /// the way Excel does. This one counts parser recursion, which parenthesised groups and
    /// right-associative operator chains also drive.
    public static let maxRecursionDepth = 512

    /// The longest chain of same-precedence operators one formula may fold.
    ///
    /// `=1+1+1+…` does not recurse to parse — precedence climbing folds it in a loop — but it
    /// does build a left-leaning tree that deep, and **releasing** an `indirect enum` that deep
    /// recurses inside the Swift runtime. Measured on a 512 KB cooperative-pool stack, a
    /// 1,000-deep tree tears down and a 3,000-deep one crashes, so this sits at 512 for a
    /// comfortable margin.
    ///
    /// A formula longer than this is refused with
    /// ``SheetError/formulaNestingTooDeep(depth:limit:)``, which means the cell keeps its
    /// cached value — the honest outcome, and one Excel would not need since it has no such
    /// limit. It takes 1,025 characters of `1+` to reach.
    public static let maxOperatorChain = 512

    /// Bracket nesting up to which a formula is parsed on the caller's own stack.
    ///
    /// Recursive descent needs stack, and a formula is untrusted input. A Swift concurrency
    /// worker gets 512 KB — a sixteenth of the main thread's — and a debug build spends
    /// several kilobytes of it per nesting level, which caps recursive descent at around 55
    /// levels of `SUM(SUM(…))`. Excel allows 64, and the failure mode here is a crash rather
    /// than an error, so anything nested deeper than this is parsed on a thread with
    /// ``deepParseStackBytes`` instead. Deep formulas are rare enough that the extra thread
    /// costs nothing in practice; shallow ones never pay for it.
    public static let inlineNestingLimit = 16

    /// Stack for the deep-parse thread.
    public static let deepParseStackBytes = 16 << 20

    private let tokens: [FormulaToken]
    private let source: String
    private let grammar: FormulaGrammar
    private let anchor: CellRef
    private let style: ReferenceStyle
    private var index = 0
    private var depth = 0
    private var callDepth = 0
    private var allowsUnion = false

    private init(
        tokens: [FormulaToken],
        source: String,
        grammar: FormulaGrammar,
        style: ReferenceStyle,
        anchor: CellRef
    ) {
        self.tokens = tokens
        self.source = source
        self.grammar = grammar
        self.style = style
        self.anchor = anchor
    }

    /// Parses formula source text (without the leading `=`).
    ///
    /// - Parameters:
    ///   - anchor: the cell the formula lives in. Only used for R1C1, where a relative
    ///     reference *is* an offset from this cell and cannot be resolved without it.
    public static func parse(
        _ source: String,
        style: ReferenceStyle = .a1,
        anchor: CellRef = .origin,
        grammar: FormulaGrammar = .default,
        argumentSeparator: Character = ","
    ) throws(SheetError) -> FormulaExpression {
        guard source.utf8.count <= Limits.maxFormulaLength else {
            throw SheetError.formulaTooLong(length: source.utf8.count, limit: Limits.maxFormulaLength)
        }
        let tokens = try FormulaLexer.tokenize(source, style: style, argumentSeparator: argumentSeparator)
        guard !tokens.isEmpty else {
            throw SheetError.invalidFormula(text: source, position: 0, reason: "the formula is empty")
        }
        var parser = FormulaParser(
            tokens: tokens, source: source, grammar: grammar, style: style, anchor: anchor
        )
        // The recursive descent below throws untyped and is re-typed here. Typed throws puts
        // a slot for the error in every frame that can propagate one, and `SheetError` is a
        // wide enum; on a 512 KB cooperative-pool stack that alone cost about a fifth of the
        // nesting depth Excel allows.
        guard maximumNesting(tokens) > inlineNestingLimit else {
            switch parser.run() {
            case let .success(expression): return expression
            case let .failure(error): throw error
            }
        }
        let captured = parser
        switch onDeepStack({ var local = captured
            return local.run()
        }) {
        case let .success(expression): return expression
        case let .failure(error): throw error
        }
    }

    /// One parse, with the untyped throws of the descent folded into a `Result`.
    private mutating func run() -> Result<FormulaExpression, SheetError> {
        do {
            let expression = try parseExpression(minimumPrecedence: 0)
            guard index == tokens.count else {
                throw SheetError.invalidFormula(
                    text: source, position: tokens[index].position, reason: "unexpected trailing input"
                )
            }
            return .success(expression)
        } catch let error as SheetError {
            return .failure(error)
        } catch {
            return .failure(.internalInconsistency(detail: "the formula parser threw \(error)"))
        }
    }

    /// The deepest bracket nesting in a token stream, which is what recursive descent costs
    /// stack for.
    static func maximumNesting(_ tokens: [FormulaToken]) -> Int {
        var depth = 0
        var maximum = 0
        for token in tokens {
            switch token.kind {
            case .leftParenthesis, .leftBrace:
                depth += 1
                maximum = Swift.max(maximum, depth)
            case .rightParenthesis, .rightBrace:
                depth -= 1
            default:
                break
            }
        }
        return maximum
    }

    /// Runs `body` on a thread with ``deepParseStackBytes`` of stack and waits for it.
    ///
    /// Blocking a cooperative worker on a semaphore is normally a mistake; it is safe here
    /// because the thread being waited on is a real one that does bounded work and always
    /// signals, so the wait cannot outlive it.
    private static func onDeepStack(
        _ body: @escaping @Sendable () -> Result<FormulaExpression, SheetError>
    ) -> Result<FormulaExpression, SheetError> {
        final class Outcome: @unchecked Sendable {
            var value: Result<FormulaExpression, SheetError>?
        }
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            outcome.value = body()
            finished.signal()
        }
        thread.stackSize = deepParseStackBytes
        thread.name = "OpenSheets.deep-formula-parse"
        thread.start()
        finished.wait()
        return outcome.value
            ?? .failure(.internalInconsistency(detail: "the deep-stack formula parse produced nothing"))
    }

    // MARK: - Precedence

    private static func infixPrecedence(_ symbol: FormulaOperator) -> Int? {
        switch symbol {
        case .equal, .notEqual, .less, .greater, .lessOrEqual, .greaterOrEqual: 1
        case .concat: 2
        case .add, .subtract: 3
        case .multiply, .divide: 4
        case .power: 5
        case .percent: nil
        }
    }

    private var unaryPrecedence: Int {
        // Sitting *above* `^` is what makes `-2^2` fold as `(-2)^2`, which is Excel; sitting
        // below it gives the mathematical `-(2^2)`. One integer, two engines.
        grammar.unaryMinusBindsTighterThanPower ? 6 : 5
    }

    // MARK: - Expressions

    private mutating func parseExpression(minimumPrecedence: Int) throws -> FormulaExpression {
        try enterRecursion()
        defer { depth -= 1 }

        var left: FormulaExpression
        if let token = peek(), case let .op(symbol) = token.kind, symbol.isPrefix {
            index += 1
            left = .unary(symbol, try parseExpression(minimumPrecedence: unaryPrecedence))
        } else {
            left = try parseOperand()
        }

        var folds = 0
        while let token = peek(), case let .op(symbol) = token.kind, symbol.isInfix,
              let precedence = FormulaParser.infixPrecedence(symbol), precedence >= minimumPrecedence {
            index += 1
            folds += 1
            // Each fold deepens the tree by one even though nothing recursed; see
            // ``maxOperatorChain``.
            guard folds <= FormulaParser.maxOperatorChain else {
                throw SheetError.formulaNestingTooDeep(depth: folds, limit: FormulaParser.maxOperatorChain)
            }
            let nextMinimum = symbol == .power && grammar.powerIsRightAssociative ? precedence : precedence + 1
            let right = try parseExpression(minimumPrecedence: nextMinimum)
            left = .binary(symbol, left, right)
        }
        return left
    }

    /// The reference operators and postfix `%`, all in one stack frame.
    ///
    /// Union, intersection and `%` were three separate methods until a 64-level nesting test
    /// overflowed a 512 KB cooperative-pool stack. Each level of `SUM(SUM(…))` costs one frame
    /// per method on the descent, so the number of methods between ``parseExpression`` and
    /// ``parsePrimary`` is a multiplier on the deepest formula we can parse. Folding them into
    /// loops here is not a micro-optimisation — it is the difference between accepting the 64
    /// levels Excel allows and crashing at 50.
    private mutating func parseOperand() throws -> FormulaExpression {
        var left = try parseRangeChain()

        var folds = 0
        while let token = peek(), token.hasLeadingWhitespace, startsReferenceOperand(token) {
            folds += 1
            guard folds <= FormulaParser.maxOperatorChain else {
                throw SheetError.formulaNestingTooDeep(depth: folds, limit: FormulaParser.maxOperatorChain)
            }
            left = .intersection(left, try parseRangeChain())
        }

        if allowsUnion, let token = peek(), case .comma = token.kind {
            var parts = [left]
            while let next = peek(), case .comma = next.kind {
                index += 1
                var part = try parseRangeChain()
                while let following = peek(), following.hasLeadingWhitespace, startsReferenceOperand(following) {
                    part = .intersection(part, try parseRangeChain())
                }
                parts.append(part)
            }
            left = .union(parts)
        }

        while let token = peek(), case .op(.percent) = token.kind {
            index += 1
            folds += 1
            guard folds <= FormulaParser.maxOperatorChain else {
                throw SheetError.formulaNestingTooDeep(depth: folds, limit: FormulaParser.maxOperatorChain)
            }
            left = .percent(left)
        }
        return left
    }

    private mutating func parseRangeChain() throws -> FormulaExpression {
        var left = try parsePrimary()
        var folds = 0
        while let token = peek(), case .colon = token.kind {
            index += 1
            folds += 1
            guard folds <= FormulaParser.maxOperatorChain else {
                throw SheetError.formulaNestingTooDeep(depth: folds, limit: FormulaParser.maxOperatorChain)
            }
            let right = try parsePrimary()
            left = .rangeOperator(left, right)
        }
        return left
    }

    /// Whether a token could begin the right-hand side of the space (intersection) operator.
    ///
    /// Restricted to reference-shaped things on purpose. Without the restriction `=1 + 2`
    /// would parse `1` and `+2` as two operands to intersect, because whitespace is
    /// significant and `+` can start an operand.
    private func startsReferenceOperand(_ token: FormulaToken) -> Bool {
        switch token.kind {
        case .reference, .nameOrReference, .structuredReference, .leftParenthesis: true
        case let .name(text): !FormulaParser.isBooleanLiteral(text)
        default: false
        }
    }

    // MARK: - Primaries

    private mutating func parsePrimary() throws -> FormulaExpression {
        try enterRecursion()
        defer { depth -= 1 }

        guard let token = peek() else {
            throw SheetError.invalidFormula(
                text: source, position: source.utf8.count, reason: "the formula ends where a value was expected"
            )
        }
        index += 1

        switch token.kind {
        case let .number(value):
            return .number(value)
        case let .string(value):
            return .string(value)
        case let .errorLiteral(value):
            return .errorLiteral(value)
        case let .structuredReference(text):
            return .unsupported(text)
        case let .reference(text):
            return try makeReference(text, at: token.position)
        case let .nameOrReference(text):
            if consumesCallParenthesis(after: text) { return try parseCall(named: text, at: token.position) }
            return try makeReference(text, at: token.position)
        case let .name(text):
            if consumesCallParenthesis(after: text) { return try parseCall(named: text, at: token.position) }
            if FormulaParser.isBooleanLiteral(text) { return .boolean(text.uppercased() == "TRUE") }
            return .name(FormulaParser.makeName(text))
        case .leftParenthesis:
            let saved = allowsUnion
            allowsUnion = true
            let inner = try parseExpression(minimumPrecedence: 0)
            allowsUnion = saved
            try expectRightParenthesis(openedAt: token.position)
            return .group(inner)
        case .leftBrace:
            return try parseArrayLiteral(openedAt: token.position)
        case let .op(symbol) where symbol.isPrefix:
            // A prefix sign where an operand was expected — `A1:-B2`, `SUM(-1)`. Hand it back
            // to the expression parser, which owns prefix operators.
            index -= 1
            return try parseExpression(minimumPrecedence: unaryPrecedence)
        default:
            throw SheetError.invalidFormula(
                text: source, position: token.position, reason: "unexpected token"
            )
        }
    }

    private func consumesCallParenthesis(after name: String) -> Bool {
        guard let next = peek(), case .leftParenthesis = next.kind else { return false }
        // `SUM (A1)` is a call in Excel, but `MyRange (A1:B2)` is an intersection. The only
        // thing that can tell them apart is whether the name is a function we know.
        guard next.hasLeadingWhitespace else { return true }
        return FunctionCatalog.isKnownName(name)
    }

    private mutating func parseCall(named rawName: String, at position: Int) throws -> FunctionCallResult {
        guard callDepth < Limits.maxFormulaNestingDepth else {
            throw SheetError.formulaNestingTooDeep(depth: callDepth + 1, limit: Limits.maxFormulaNestingDepth)
        }
        callDepth += 1
        defer { callDepth -= 1 }

        index += 1 // the `(`
        let resolved = FunctionNames.normalize(rawName)
        var arguments: [FormulaExpression] = []
        let saved = allowsUnion
        allowsUnion = false
        defer { allowsUnion = saved }

        if let next = peek(), case .rightParenthesis = next.kind {
            index += 1
            return .call(FunctionCall(name: resolved.name, wasPrefixed: resolved.wasPrefixed, arguments: []))
        }
        while true {
            if let next = peek(), isArgumentTerminator(next) {
                arguments.append(.missing)
            } else {
                arguments.append(try parseExpression(minimumPrecedence: 0))
            }
            guard let next = peek(), case .comma = next.kind else { break }
            index += 1
        }
        try expectRightParenthesis(openedAt: position)
        return .call(FunctionCall(name: resolved.name, wasPrefixed: resolved.wasPrefixed, arguments: arguments))
    }

    private typealias FunctionCallResult = FormulaExpression

    private func isArgumentTerminator(_ token: FormulaToken) -> Bool {
        switch token.kind {
        case .comma, .rightParenthesis: true
        default: false
        }
    }

    private mutating func expectRightParenthesis(openedAt position: Int) throws {
        guard let next = peek(), case .rightParenthesis = next.kind else {
            throw SheetError.invalidFormula(text: source, position: position, reason: "unbalanced parentheses")
        }
        index += 1
    }

    private mutating func parseArrayLiteral(openedAt position: Int) throws -> FormulaExpression {
        var rows: [[ScalarValue]] = []
        var row: [ScalarValue] = []
        while true {
            guard let token = peek() else {
                throw SheetError.invalidFormula(text: source, position: position, reason: "unterminated array literal")
            }
            if case .rightBrace = token.kind {
                index += 1
                rows.append(row)
                break
            }
            row.append(try parseArrayElement())
            guard let separator = peek() else {
                throw SheetError.invalidFormula(text: source, position: position, reason: "unterminated array literal")
            }
            switch separator.kind {
            case .comma:
                index += 1
            case .semicolon:
                index += 1
                rows.append(row)
                row = []
            case .rightBrace:
                continue
            default:
                throw SheetError.invalidFormula(
                    text: source, position: separator.position, reason: "an array literal holds only constants"
                )
            }
        }
        guard !rows.isEmpty, !rows.contains(where: \.isEmpty) else {
            throw SheetError.invalidFormula(text: source, position: position, reason: "an array literal cannot be empty")
        }
        return .array(ArrayLiteral(rows: rows))
    }

    private mutating func parseArrayElement() throws -> ScalarValue {
        var sign = 1.0
        while let token = peek(), case let .op(symbol) = token.kind, symbol.isPrefix {
            if symbol == .subtract { sign *= -1 }
            index += 1
        }
        guard let token = peek() else {
            throw SheetError.invalidFormula(
                text: source, position: source.utf8.count, reason: "the array literal ends early"
            )
        }
        index += 1
        switch token.kind {
        case let .number(value): return .number(sign * value)
        case let .string(value): return .text(value)
        case let .errorLiteral(value): return .error(value)
        case let .name(text) where FormulaParser.isBooleanLiteral(text): return .boolean(text.uppercased() == "TRUE")
        default:
            throw SheetError.invalidFormula(
                text: source, position: token.position, reason: "an array literal holds only constants"
            )
        }
    }

    // MARK: - Helpers

    private mutating func makeReference(_ text: String, at position: Int) throws -> FormulaExpression {
        let reference = style == .r1c1
            ? FormulaReference(r1c1Text: text, anchor: anchor)
            : FormulaReference(a1Text: text)
        guard let reference else {
            // A sheet-qualified name lexes as a reference candidate; fall back to a name
            // rather than rejecting `Sheet1!Total`.
            if text.contains("!") { return .name(FormulaParser.makeName(text)) }
            throw SheetError.invalidFormula(text: source, position: position, reason: "'\(text)' is not a reference")
        }
        return .reference(reference)
    }

    private static func makeName(_ text: String) -> NameReference {
        guard let separator = text.lastIndex(of: "!") else { return NameReference(name: text) }
        var sheet = String(text[text.startIndex ..< separator])
        var workbook: String?
        if sheet.hasPrefix("["), let close = sheet.firstIndex(of: "]") {
            workbook = String(sheet[sheet.startIndex ... close])
            sheet = String(sheet[sheet.index(after: close)...])
        }
        if sheet.hasPrefix("'"), sheet.hasSuffix("'"), sheet.count >= 2 {
            sheet = String(sheet.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        let name = String(text[text.index(after: separator)...])
        guard !sheet.isEmpty || workbook != nil else { return NameReference(name: name) }
        return NameReference(qualifier: SheetQualifier(workbook: workbook, name: sheet), name: name)
    }

    static func isBooleanLiteral(_ text: String) -> Bool {
        let upper = text.uppercased()
        return upper == "TRUE" || upper == "FALSE"
    }

    private func peek() -> FormulaToken? {
        index < tokens.count ? tokens[index] : nil
    }

    private mutating func enterRecursion() throws {
        depth += 1
        guard depth <= FormulaParser.maxRecursionDepth else {
            throw SheetError.formulaNestingTooDeep(depth: depth, limit: FormulaParser.maxRecursionDepth)
        }
    }
}
