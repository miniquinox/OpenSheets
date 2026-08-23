import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// The cases where Excel and LibreOffice give different error kinds.
///
/// WAVE-1-ADDENDUM §4: A7's fixture corpus deliberately only uses formulas the two engines
/// agree on, so a green corpus does **not** prove our error kinds are right. These are the
/// disagreements, and Excel wins every one of them.
struct ExcelVersusLibreOfficeTests {
    private func evaluate(_ source: String) -> CellOutcome {
        FormulaEngine(options: TestWorkbook.options)
            .evaluate(source, at: TestWorkbook.origin, in: TestWorkbook.make())
    }

    @Test func rootOfANegativeIsNumberNotValue() {
        // Excel: #NUM!. LibreOffice: #VALUE!.
        #expect(evaluate("SQRT(-1)") == .value(.error(.invalidNumber)))
        #expect(evaluate("SQRT(-0.0001)") == .value(.error(.invalidNumber)))
        #expect(evaluate("POWER(-8,1/3)") == .value(.error(.invalidNumber)))
    }

    @Test func offsetOffTheSheetIsRefNotValue() {
        // Excel: #REF!. LibreOffice: #VALUE!.
        #expect(evaluate("OFFSET($Z$1,-100,0)") == .value(.error(.invalidReference)))
        #expect(evaluate("OFFSET(Data!A1,0,-1)") == .value(.error(.invalidReference)))
        #expect(evaluate("OFFSET(Data!A1,-1,0)") == .value(.error(.invalidReference)))
    }

    @Test func logarithmsOutOfDomainAreNumber() {
        #expect(evaluate("LN(0)") == .value(.error(.invalidNumber)))
        #expect(evaluate("LN(-5)") == .value(.error(.invalidNumber)))
        #expect(evaluate("LOG10(-1)") == .value(.error(.invalidNumber)))
        #expect(evaluate("LOG(10,-2)") == .value(.error(.invalidNumber)))
    }

    @Test func inverseTrigonometryOutOfDomainIsNumber() {
        #expect(evaluate("ASIN(1.5)") == .value(.error(.invalidNumber)))
        #expect(evaluate("ACOS(-1.5)") == .value(.error(.invalidNumber)))
    }

    @Test func aColumnIndexPastTheTableIsRefButABadOneIsValue() {
        // Two different mistakes, two different errors, and Excel distinguishes them.
        #expect(evaluate("VLOOKUP(\"beta\",Data!B1:C6,3,FALSE())") == .value(.error(.invalidReference)))
        #expect(evaluate("VLOOKUP(\"beta\",Data!B1:C6,0,FALSE())") == .value(.error(.wrongType)))
    }

    @Test func indexPastTheEndIsRef() {
        #expect(evaluate("INDEX(Data!A1:A6,7)") == .value(.error(.invalidReference)))
        #expect(evaluate("INDEX(Data!A1:A6,1,2)") == .value(.error(.invalidReference)))
    }

    @Test func floorAndCeilingDisagreeAboutAZeroStep() {
        // Not a typo on our side: `CEILING(5,0)` is 0 and `FLOOR(5,0)` is `#DIV/0!` in Excel.
        #expect(evaluate("CEILING(5,0)") == .value(.number(0)))
        #expect(evaluate("FLOOR(5,0)") == .value(.error(.divideByZero)))
    }

    @Test func anEmptyIntersectionIsNull() {
        #expect(evaluate("SUM(Data!A1:A6 Data!C1:C6)") == .value(.error(.nullIntersection)))
    }

    @Test func aMissingSheetIsRefAndAMissingFunctionIsName() {
        #expect(evaluate("NoSuchSheet!A1") == .value(.error(.invalidReference)))
        #expect(evaluate("NOSUCHFUNCTION(1)") == .value(.error(.unknownName)))
    }

    @Test func overflowIsNumberRatherThanInfinity() {
        #expect(evaluate("1e308*1e10") == .value(.error(.invalidNumber)))
        #expect(evaluate("EXP(1000)") == .value(.error(.invalidNumber)))
    }
}

/// Coercion rules that are Excel's and not Swift's.
struct CoercionTests {
    private func evaluate(_ source: String) -> CellOutcome {
        FormulaEngine(options: TestWorkbook.options)
            .evaluate(source, at: TestWorkbook.origin, in: TestWorkbook.make())
    }

    @Test func booleansAreNumbersInArithmetic() {
        #expect(evaluate("TRUE+1") == .value(.number(2)))
        #expect(evaluate("FALSE+1") == .value(.number(1)))
        #expect(evaluate("TRUE*5") == .value(.number(5)))
    }

    @Test func aBlankIsZeroButNotAnEmptyString() {
        #expect(evaluate("Data!E4+1") == .value(.number(1)))
        #expect(evaluate("Data!E4&\"x\"") == .value(.text("x")))
        #expect(evaluate("ISBLANK(Data!E4)") == .value(.boolean(true)))
        #expect(evaluate("ISBLANK(Data!E3)") == .value(.boolean(false)), "E3 holds \"\", which is not blank")
        #expect(evaluate("COUNTA(Data!E3:E3)") == .value(.number(1)), "an empty string still counts")
    }

    @Test func textCoercesInArithmeticButNotInComparison() {
        #expect(evaluate("\"42\"+1") == .value(.number(43)))
        #expect(evaluate("\"42\"=42") == .value(.boolean(false)))
        #expect(evaluate("\"abc\"+1") == .value(.error(.wrongType)))
    }

    @Test func referencedTextIsSkippedRatherThanCoerced() {
        // The rule that stops a stray header changing a total.
        #expect(evaluate("SUM(Data!E5)") == .value(.number(0)), "E5 holds the text \"42\"")
        #expect(evaluate("SUM(\"42\")") == .value(.number(42)), "but a directly written \"42\" is coerced")
    }

    @Test func theFirstErrorInArgumentOrderWins() {
        #expect(evaluate("SUM(1/0,NA())") == .value(.error(.divideByZero)))
        #expect(evaluate("SUM(NA(),1/0)") == .value(.error(.notAvailable)))
        #expect(evaluate("1/0+NA()") == .value(.error(.divideByZero)))
        #expect(evaluate("NA()+1/0") == .value(.error(.notAvailable)))
    }

    @Test func mixedTypesRankNumberThenTextThenBoolean() {
        #expect(evaluate("1<\"1\"") == .value(.boolean(true)))
        #expect(evaluate("\"zzz\"<TRUE") == .value(.boolean(true)))
        #expect(evaluate("999999<\"a\"") == .value(.boolean(true)))
    }

    @Test func textComparisonIsCaseInsensitive() {
        #expect(evaluate("\"a\"=\"A\"") == .value(.boolean(true)))
        #expect(evaluate("EXACT(\"a\",\"A\")") == .value(.boolean(false)))
    }
}

/// Number semantics: 15 significant digits, and the cosmetic zero.
struct NumberSemanticsTests {
    @Test func fifteenSignificantDigitsIsWhereRoundingHappens() {
        #expect(ExcelNumber.round15(1.0 / 3.0) == 0.333333333333333)
        #expect(ExcelNumber.round15(123456789012345.678) == 123456789012346)
        #expect(ExcelNumber.equal(0.1 + 0.2, 0.3))
        #expect(!ExcelNumber.equal(0.1, 0.1 + 1e-14))
    }

    @Test func cancellationNearZeroSnapsToZero() {
        #expect(ExcelNumber.subtract(ExcelNumber.add(0.1, 0.2), 0.3) == 0)
        #expect(ExcelNumber.subtract(1.0, 1.0) == 0)
    }

    @Test func aRealSmallDifferenceIsNotSnappedAway() {
        // `=1-0.99999999999999` is 1e-14 in Excel, not 0. Snapping it would be a wrong answer,
        // not a cosmetic one.
        let difference = ExcelNumber.subtract(1.0, 0.99999999999999)
        #expect(difference != 0)
        #expect(difference > 5e-15 && difference < 2e-14, "got \(difference)")
    }

    @Test func generalTextMatchesExcelsSpelling() {
        #expect(ExcelNumber.generalText(0) == "0")
        #expect(ExcelNumber.generalText(1) == "1")
        #expect(ExcelNumber.generalText(1.5) == "1.5")
        #expect(ExcelNumber.generalText(-2.25) == "-2.25")
        #expect(ExcelNumber.generalText(1e15).hasPrefix("1E"))
        #expect(ExcelNumber.generalText(1e-6).hasPrefix("1E"))
    }

    @Test func nonFiniteResultsBecomeNumberErrors() {
        #expect(ExcelNumber.checked(.infinity) == .error(.invalidNumber))
        #expect(ExcelNumber.checked(.nan) == .error(.invalidNumber))
        #expect(ExcelNumber.checked(1.5) == .number(1.5))
    }

    @Test func dateArithmeticHonoursTheWorkbooksEpoch() {
        // The same formula, two epochs, two answers — and neither is 1900 by assumption.
        var sheet = Sheet(id: SheetID(1), name: "S")
        try? sheet.cells.setCell(.number(0), at: .origin)
        let workbook = Workbook(sheets: [sheet])

        let nineteenHundred = FormulaEngine(options: EvaluationOptions(dateSystem: .excel1900))
        let nineteenOhFour = FormulaEngine(options: EvaluationOptions(dateSystem: .excel1904))
        let cell = SheetCell(sheet: SheetID(1), ref: .origin)

        #expect(nineteenHundred.evaluate("DATE(2024,3,15)", at: cell, in: workbook) == .value(.number(45_366)))
        #expect(nineteenOhFour.evaluate("DATE(2024,3,15)", at: cell, in: workbook) == .value(.number(43_904)))
        #expect(nineteenHundred.evaluate("YEAR(45366)", at: cell, in: workbook) == .value(.number(2024)))
        #expect(nineteenOhFour.evaluate("YEAR(45366)", at: cell, in: workbook) == .value(.number(2028)))
    }
}

/// Unsupported formulas round-trip untouched.
struct UnsupportedFormulaTests {
    @Test func aKnownExcelFunctionWeDoNotImplementIsUnsupportedRatherThanWrong() {
        let engine = FormulaEngine(options: TestWorkbook.options)
        let workbook = TestWorkbook.make()
        for source in ["LAMBDA(x,x)", "LET(x,1,x)", "FILTER(Data!A1:A6,TRUE())", "PMT(1,2,3)", "XIRR(1,2)"] {
            guard case .keepCached = engine.evaluate(source, at: TestWorkbook.origin, in: workbook) else {
                Issue.record("\(source) should be unsupported, not evaluated")
                continue
            }
        }
    }

    @Test func anUnknownNameIsStillName() {
        let engine = FormulaEngine(options: TestWorkbook.options)
        let outcome = engine.evaluate("WOMBAT(1)", at: TestWorkbook.origin, in: TestWorkbook.make())
        #expect(outcome == .value(.error(.unknownName)))
    }

    @Test func theUnsupportedReasonNamesTheFunction() {
        let engine = FormulaEngine(options: TestWorkbook.options)
        guard case let .keepCached(reason) = engine.evaluate(
            "SUM(1,LAMBDA(x,x))", at: TestWorkbook.origin, in: TestWorkbook.make()
        ) else {
            Issue.record("expected an unsupported outcome")
            return
        }
        #expect(reason == .function("LAMBDA"))
        #expect(reason.message.contains("LAMBDA"))
    }

    @Test func anUnsupportedFormulaSurvivesAParseAndWriteRoundTrip() throws {
        for source in ["LAMBDA(x,x+1)", "Table1[#Data]", "FILTER(A1:A9,B1:B9>0)", "LET(x,1,x*2)"] {
            let expression = try FormulaSyntax.parse(source)
            #expect(FormulaSyntax.write(expression) == source)
        }
    }

    @Test func unsupportedFunctionsThatNeedThePrefixKeepItOnTheWayBackOut() throws {
        #expect(try FormulaSyntax.toStorage("FILTER(A1:A9,B1:B9>0)") == "_xlfn.FILTER(A1:A9,B1:B9>0)")
        #expect(try FormulaSyntax.toStorage("LAMBDA(x,x)") == "_xlfn.LAMBDA(x,x)")
    }
}

/// `_xlfn.` mapping, both ways.
struct StoredFunctionNameTests {
    static let nineFromTheAddendum = [
        "IFS", "SWITCH", "CONCAT", "TEXTJOIN", "XLOOKUP", "MAXIFS", "MINIFS", "STDEV.P", "STDEV.S",
    ]

    @Test func theNineFunctionsInTheAddendumAllNeedThePrefix() {
        for name in StoredFunctionNameTests.nineFromTheAddendum {
            #expect(FunctionNames.storedName(forDisplay: name) == "_xlfn." + name)
            #expect(FunctionNames.displayName(forStored: "_xlfn." + name) == name)
        }
    }

    @Test func aFunctionThatDoesNotNeedThePrefixDoesNotGetOne() {
        for name in ["SUM", "AVERAGE", "VLOOKUP", "IF", "LEFT", "DATE"] {
            #expect(FunctionNames.storedName(forDisplay: name) == name)
        }
    }

    @Test func theStoredSpellingParsesAndTheDisplaySpellingComesBack() throws {
        for name in StoredFunctionNameTests.nineFromTheAddendum {
            let expression = try FormulaSyntax.parse("_xlfn.\(name)(1)")
            guard case let .call(call) = expression else {
                Issue.record("_xlfn.\(name) did not parse as a call")
                continue
            }
            #expect(call.name == name)
            #expect(call.wasPrefixed)
            #expect(FormulaSyntax.write(expression, format: .display) == "\(name)(1)")
            #expect(FormulaSyntax.write(expression, format: .storage) == "_xlfn.\(name)(1)")
        }
    }

    @Test func theDisplaySpellingIsWrittenBackWithThePrefix() throws {
        // The user types `XLOOKUP`; the file has to say `_xlfn.XLOOKUP` or Excel shows #NAME?.
        #expect(try FormulaSyntax.toStorage("XLOOKUP(A1,B1:B9,C1:C9)") == "_xlfn.XLOOKUP(A1,B1:B9,C1:C9)")
        #expect(try FormulaSyntax.toDisplay("_xlfn.XLOOKUP(A1,B1:B9,C1:C9)") == "XLOOKUP(A1,B1:B9,C1:C9)")
    }

    @Test func stackedNamespacePrefixesAreStripped() {
        #expect(FunctionNames.normalize("_xlfn._xlws.FILTER").name == "FILTER")
        #expect(FunctionNames.normalize("_xlfn._xlws.FILTER").wasPrefixed)
    }

    @Test func nestedPrefixedCallsRoundTrip() throws {
        let source = "_xlfn.IFS(A1>0,_xlfn.CONCAT(\"a\",\"b\"),TRUE,_xlfn.TEXTJOIN(\",\",TRUE,B1:B9))"
        let expression = try FormulaSyntax.parse(source)
        #expect(FormulaSyntax.write(expression, format: .storage) == source)
    }
}
