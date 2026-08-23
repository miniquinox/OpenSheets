import Foundation
import SheetModel
import Testing
@testable import SheetFormula

struct LexerTests {
    @Test func lexesNumbersIncludingScientificNotation() throws {
        #expect(try tokenKinds("1") == ["number(1.0)"])
        #expect(try tokenKinds("1.5") == ["number(1.5)"])
        #expect(try tokenKinds("1e3") == ["number(1000.0)"])
        #expect(try tokenKinds("1E-3") == ["number(0.001)"])
        #expect(try tokenKinds("1.5e+2") == ["number(150.0)"])
    }

    @Test func lexesStringsWithDoubledQuoteEscapes() throws {
        let tokens = try FormulaLexer.tokenize("\"a\"\"b\"")
        guard case let .string(value) = tokens[0].kind else {
            Issue.record("expected a string token")
            return
        }
        #expect(value == "a\"b")
    }

    @Test func rejectsAnUnterminatedString() {
        #expect(throws: SheetError.self) { try FormulaLexer.tokenize("\"abc") }
    }

    @Test func lexesEveryErrorLiteral() throws {
        for error in CellError.allCases where error.isExcelNative {
            let tokens = try FormulaLexer.tokenize(error.rawValue)
            guard case let .errorLiteral(value) = tokens.first?.kind else {
                Issue.record("\(error.rawValue) did not lex as an error literal")
                continue
            }
            #expect(value == error)
        }
    }

    @Test func distinguishesAReferenceFromAFunctionNameThatLooksLikeOne() throws {
        // `LOG10` is a valid cell address — column 8509, row 10 — and a function name.
        // Only the next token can tell them apart.
        guard case .nameOrReference("LOG10") = try FormulaLexer.tokenize("LOG10")[0].kind else {
            Issue.record("LOG10 alone should be ambiguous")
            return
        }
        let call = try FormulaSyntax.parse("LOG10(100)")
        guard case let .call(function) = call, function.name == "LOG10" else {
            Issue.record("LOG10( should parse as a call")
            return
        }
        let reference = try FormulaSyntax.parse("LOG10")
        guard case let .reference(ref) = reference else {
            Issue.record("bare LOG10 should parse as a reference")
            return
        }
        #expect(ref.a1Text == "LOG10")
    }

    @Test func recordsLeadingWhitespaceBecauseTheIntersectionOperatorIsASpace() throws {
        let tokens = try FormulaLexer.tokenize("A1:B5 B1:C5")
        #expect(tokens.count == 2)
        #expect(tokens[1].hasLeadingWhitespace)
    }

    @Test func lexesQuotedSheetNamesWithEscapedApostrophes() throws {
        let reference = try FormulaSyntax.parse("'Bob''s Sheet'!A1")
        guard case let .reference(value) = reference else {
            Issue.record("expected a reference")
            return
        }
        #expect(value.qualifier?.name == "Bob's Sheet")
        #expect(value.a1Text == "'Bob''s Sheet'!A1")
    }

    @Test func lexesExternalWorkbookReferences() throws {
        let reference = try FormulaSyntax.parse("[1]Ext!A1")
        guard case let .reference(value) = reference else {
            Issue.record("expected a reference")
            return
        }
        #expect(value.qualifier?.workbook == "[1]")
        #expect(value.qualifier?.isExternal == true)
    }

    @Test func lexesWholeColumnAndWholeRowReferences() throws {
        for (text, shape) in [("A:A", ReferenceShape.columns), ("1:1", .rows), ("B:D", .columns), ("2:10", .rows)] {
            guard case let .reference(value) = try FormulaSyntax.parse(text) else {
                Issue.record("\(text) did not parse as a reference")
                continue
            }
            #expect(value.shape == shape)
            #expect(value.a1Text == text)
        }
    }

    @Test func capturesStructuredTableReferencesWithoutInterpretingThem() throws {
        let expression = try FormulaSyntax.parse("Table1[#Data]")
        #expect(expression.containsUnsupportedSyntax)
        #expect(FormulaWriter.write(expression) == "Table1[#Data]")
    }

    private func tokenKinds(_ source: String) throws -> [String] {
        try FormulaLexer.tokenize(source).map { token in
            if case let .number(value) = token.kind { return "number(\(value))" }
            return "\(token.kind)"
        }
    }
}

struct PrecedenceTests {
    /// The primary suite: **Excel's** folding, which is the default.
    ///
    /// The first two rows are the ones that make this suite worth having. `-2^2` is `4` in
    /// Excel because unary minus binds tighter than `^`, and `2^3^2` is `64` because `^`
    /// associates left to right. Both disagree with ordinary mathematics, and both are what a
    /// real `.xlsx` file means — see ``FormulaGrammar``.
    @Test(arguments: [
        ("-2^2", 4.0),
        ("2^3^2", 64.0),
        ("-3^2", 9.0),
        ("(-2)^2", 4.0),
        ("2^2^3", 64.0),
        ("-2^-2", 0.25),
        ("2*3^2", 18.0),
        ("-2*3", -6.0),
        ("2-3-4", -5.0),
        ("100/10/2", 5.0),
        ("2+3*4^2", 50.0),
        ("50%*2", 1.0),
        ("-50%", -0.5),
        ("2^3%", 1.0210121257071935),
        ("2^-1", 0.5),
    ])
    func excelGrammarIsTheDefault(_ source: String, _ expected: Double) throws {
        let value = try evaluate(source, grammar: .default)
        #expect(ExcelNumber.equal(value, expected), "\(source) gave \(value), expected \(expected)")
    }

    /// The opt-in mathematical reading, kept working so the divergence stays visible in code
    /// rather than only in prose. Nothing in the product selects this today.
    @Test(arguments: [
        ("-2^2", -4.0),
        ("2^3^2", 512.0),
        ("-3^2", -9.0),
        ("(-2)^2", 4.0),
        ("2^2^3", 256.0),
        ("-2^-2", -0.25),
        ("2*3^2", 18.0),
        ("-2*3", -6.0),
        ("2+3*4^2", 50.0),
    ])
    func mathematicalGrammarIsAvailableButNotTheDefault(_ source: String, _ expected: Double) throws {
        let value = try evaluate(source, grammar: .mathematical)
        #expect(ExcelNumber.equal(value, expected), "\(source) gave \(value), expected \(expected)")
    }

    /// If someone redefines `.default`, this fails before anything subtler does.
    @Test func theDefaultGrammarIsExcels() {
        #expect(FormulaGrammar.default == FormulaGrammar.excel)
        #expect(FormulaGrammar.default.unaryMinusBindsTighterThanPower)
        #expect(!FormulaGrammar.default.powerIsRightAssociative)
        #expect(EvaluationOptions().grammar == .excel, "the engine's own default has to agree")
    }

    @Test func concatenationChainsLeftToRight() throws {
        let engine = FormulaEngine(options: TestWorkbook.options)
        let outcome = engine.evaluate("1&2&3", at: TestWorkbook.origin, in: TestWorkbook.make())
        #expect(outcome == .value(.text("123")))
    }

    @Test func comparisonBindsLoosestOfAll() {
        let engine = FormulaEngine(options: TestWorkbook.options)
        let workbook = TestWorkbook.make()
        // Parsed as `(1+1)=2`, not `1+(1=2)`.
        #expect(engine.evaluate("1+1=2", at: TestWorkbook.origin, in: workbook) == .value(.boolean(true)))
        // `&` binds tighter than `=`, so this is `("12")=("12")` and not `1&(2=12)`.
        #expect(engine.evaluate("1&2=\"12\"", at: TestWorkbook.origin, in: workbook) == .value(.boolean(true)))
        // And the number 12 is *not* equal to the text "12", which is the coercion rule.
        #expect(engine.evaluate("1&2=12", at: TestWorkbook.origin, in: workbook) == .value(.boolean(false)))
    }

    @Test func intersectionBindsTighterThanArithmetic() throws {
        let engine = FormulaEngine(options: TestWorkbook.options)
        // `A1:C1 A1:A6` is the single cell A1, so the sum is 10 and not 10 + something.
        let outcome = engine.evaluate(
            "SUM(Data!A1:C1 Data!A1:A6)+1", at: TestWorkbook.origin, in: TestWorkbook.make()
        )
        #expect(outcome == .value(.number(11)))
    }

    @Test func rangeOperatorBindsTightestOfAll() throws {
        let engine = FormulaEngine(options: TestWorkbook.options)
        let outcome = engine.evaluate("SUM(Data!A1:A3)*2", at: TestWorkbook.origin, in: TestWorkbook.make())
        #expect(outcome == .value(.number(120)))
    }

    private func evaluate(_ source: String, grammar: FormulaGrammar) throws -> Double {
        var options = TestWorkbook.options
        options.grammar = grammar
        let engine = FormulaEngine(options: options)
        let outcome = engine.evaluate(source, at: TestWorkbook.origin, in: TestWorkbook.make())
        guard case let .value(.number(value)) = outcome else {
            throw SheetError.invalidFormula(text: source, position: nil, reason: "expected a number, got \(outcome)")
        }
        return value
    }
}

struct ParserRoundTripTests {
    @Test(arguments: [
        "1+1",
        "SUM(A1:A9)",
        "SUM($A$1:$B$9)",
        "Sheet2!A1",
        "'My Sheet'!A1:B2",
        "[1]Ext!A1",
        "A:A",
        "1:1",
        "IF(A1>0,\"yes\",\"no\")",
        "IF(A1,,0)",
        "SUM((A1:A2,C1:C2))",
        "SUM(A1:B5 B1:C5)",
        "{1,2;3,4}",
        "-A1",
        "A1%",
        "(A1+A2)*3",
        "CONCAT(\"a\"\"b\",\"c\")",
        "#REF!",
        "SUM()",
        "Total*2",
        "Sheet1!Total",
    ])
    func writingAParsedFormulaGivesBackTheSameText(_ source: String) throws {
        let expression = try FormulaSyntax.parse(source)
        #expect(FormulaSyntax.write(expression) == source)
    }

    @Test func parenthesesArePreservedRatherThanSimplified() throws {
        // Dropping redundant parentheses would be a diff the user never asked for.
        let expression = try FormulaSyntax.parse("(A1+A2)+A3")
        #expect(FormulaSyntax.write(expression) == "(A1+A2)+A3")
    }

    @Test func rejectsUnbalancedParentheses() {
        #expect(throws: SheetError.self) { try FormulaSyntax.parse("SUM(A1") }
        #expect(throws: SheetError.self) { try FormulaSyntax.parse("SUM(A1))") }
    }

    @Test func rejectsAFormulaThatIsTooLong() {
        let source = String(repeating: "1+", count: 5000) + "1"
        #expect(throws: SheetError.self) { try FormulaSyntax.parse(source) }
    }

    /// Excel's own ceiling is 64 nested functions, so 64 has to work and 65 has to be refused
    /// — refused with an error, never with a crash. Deeply nested formulas are parsed on a
    /// thread with a large stack precisely so that this boundary is Excel's rather than the
    /// cooperative pool's 512 KB.
    @Test func acceptsExactlyTheNestingDepthExcelDoes() throws {
        let accepted = String(repeating: "SUM(", count: 64) + "1" + String(repeating: ")", count: 64)
        #expect(throws: Never.self) { try FormulaSyntax.parse(accepted) }

        let refused = String(repeating: "SUM(", count: 65) + "1" + String(repeating: ")", count: 65)
        do {
            _ = try FormulaSyntax.parse(refused)
            Issue.record("65 levels should be refused")
        } catch {
            guard case let .formulaNestingTooDeep(depth, limit) = error else {
                Issue.record("expected .formulaNestingTooDeep, got \(error)")
                return
            }
            #expect(depth == 65)
            #expect(limit == Limits.maxFormulaNestingDepth)
        }
    }

    @Test func acceptsALongLeftAssociativeChainWithoutRecursing() throws {
        // 400 additions. A parser that recursed per operator, or a writer that recursed down
        // the left spine, would be 400 frames deep here; both are loops instead.
        let source = Array(repeating: "1", count: 400).joined(separator: "+")
        let expression = try FormulaSyntax.parse(source)
        #expect(FormulaSyntax.write(expression) == source)
        let engine = FormulaEngine(options: TestWorkbook.options)
        #expect(engine.evaluate(source, at: TestWorkbook.origin, in: TestWorkbook.make())
            == .value(.number(400)))
    }

    /// The one place we are stricter than Excel, and it is a deliberate safety limit: a tree
    /// this deep cannot be *released* without recursing inside the Swift runtime.
    @Test func refusesAnOperatorChainLongerThanTheTeardownLimit() {
        let source = Array(repeating: "1", count: FormulaParser.maxOperatorChain + 100).joined(separator: "+")
        #expect(throws: SheetError.self) { try FormulaSyntax.parse(source) }
    }

    @Test func aChainAtExactlyTheLimitStillParses() throws {
        let source = Array(repeating: "1", count: FormulaParser.maxOperatorChain).joined(separator: "+")
        #expect(throws: Never.self) { try FormulaSyntax.parse(source) }
    }

    @Test func validateReportsAWrongArgumentCount() {
        #expect(throws: SheetError.self) { try FormulaSyntax.validate("ABS(1,2)") }
        #expect(throws: Never.self) { try FormulaSyntax.validate("ABS(1)") }
    }

    @Test func reportsThePositionOfASyntaxError() throws {
        do {
            _ = try FormulaSyntax.parse("1+@")
            Issue.record("expected a parse failure")
        } catch {
            guard case let .invalidFormula(_, position, _) = error else {
                Issue.record("expected .invalidFormula, got \(error)")
                return
            }
            #expect(position == 2)
        }
    }
}
