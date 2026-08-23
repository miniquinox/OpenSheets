//
//  FormulaReferenceTests.swift
//  SheetFormatTests
//
//  A1. Shared-formula translation, external-link detection, and the width conversion A2 has to
//  invert.
//

import Foundation
import Testing

import SheetFormat
import SheetModel
import TestSupport

@Suite("formula reference arithmetic")
struct FormulaReferenceTests {
    private func translate(_ source: String, from anchor: String, to destination: String) throws -> String {
        FormulaReferences.translate(
            source,
            from: try #require(CellRef(a1: anchor)),
            to: try #require(CellRef(a1: destination))
        )
    }

    @Test("relative references move with the copy and anchored ones do not")
    func translatesRelativeReferences() throws {
        #expect(try translate("A1*2", from: "B1", to: "B3") == "A3*2")
        #expect(try translate("$A1*2", from: "B1", to: "C3") == "$A3*2")
        #expect(try translate("A$1*2", from: "B1", to: "C3") == "B$1*2")
        #expect(try translate("$A$1*2", from: "B1", to: "C3") == "$A$1*2")
        #expect(try translate("SUM(A1:A3)", from: "B1", to: "B4") == "SUM(A4:A6)")
    }

    @Test("a function name that looks like a reference is left alone")
    func doesNotRewriteFunctionNames() throws {
        // `LOG10(` reads as column LOG row 10 to a careless scanner.
        #expect(try translate("LOG10(A1)", from: "B1", to: "B2") == "LOG10(A2)")
        #expect(try translate("SUM(A1)+LOG10(B1)", from: "C1", to: "C2") == "SUM(A2)+LOG10(B2)")
        #expect(try translate("IF(A1>0,\"A1\",\"B2\")", from: "B1", to: "B2") == "IF(A2>0,\"A1\",\"B2\")")
    }

    @Test("quoted sheet names and string literals are copied verbatim")
    func doesNotRewriteQuotedText() throws {
        #expect(try translate("'Far Away'!A1", from: "B1", to: "B2") == "'Far Away'!A2")
        #expect(try translate("\"row A1 of 3\"&A1", from: "B1", to: "B2") == "\"row A1 of 3\"&A2")
        #expect(try translate("Sheet1!A1+Total", from: "B1", to: "B2") == "Sheet1!A2+Total")
    }

    @Test("a reference pushed off the sheet becomes #REF!, which is what Excel stores")
    func translatesOffSheetToRefError() throws {
        #expect(try translate("A1*2", from: "B2", to: "B1") == "#REF!*2")
        #expect(try translate("A1", from: "B1", to: "A1") == "#REF!")
    }

    @Test("a defined name is not a reference")
    func leavesDefinedNamesAlone() throws {
        #expect(try translate("SUM(Revenue)", from: "B1", to: "B9") == "SUM(Revenue)")
        #expect(try translate("Q1_2024", from: "B1", to: "B9") == "Q1_2024")
        #expect(try translate("TRUE", from: "B1", to: "B9") == "TRUE")
    }

    @Test("scientific notation is not a reference")
    func leavesNumbersAlone() throws {
        #expect(try translate("1.5E+10*A1", from: "B1", to: "B2") == "1.5E+10*A2")
    }

    // MARK: - External links

    @Test("a bracketed workbook prefix means external")
    func detectsExternalWorkbooks() {
        #expect(FormulaReferences.referencesExternalWorkbook("[1]Sheet1!A1"))
        #expect(FormulaReferences.referencesExternalWorkbook("[1]Sheet1!A1*2"))
        #expect(FormulaReferences.referencesExternalWorkbook("SUM([1]Sheet1!A1:A5)"))
        #expect(FormulaReferences.referencesExternalWorkbook("'[1]Sheet1'!A1"))
        #expect(FormulaReferences.referencesExternalWorkbook("'[Budget 2024.xlsx]Q1'!A1"))
    }

    @Test("a structured table reference is not external")
    func doesNotFlagStructuredReferences() {
        #expect(!FormulaReferences.referencesExternalWorkbook("SUM(Table1[Amount])"))
        #expect(!FormulaReferences.referencesExternalWorkbook("Table1[[#Headers],[Amount]]"))
        #expect(!FormulaReferences.referencesExternalWorkbook("SUM(A1:A9)"))
        #expect(!FormulaReferences.referencesExternalWorkbook("\"a [1] in text\""))
    }
}

@Suite("column width conversion")
struct ColumnMetricsTests {
    @Test("Excel's default column is 64 pixels, which is 48 points")
    func defaultWidth() {
        // 8.43 characters × 7 px + 5 px padding = 64 px = 48 pt, which is what Excel shows.
        #expect(abs(XLSXColumnMetrics.points(fromCharacters: 8.43) - 48) < 0.01)
    }

    /// **The reader and the writer share one conversion**, and this is the reason.
    ///
    /// `XLSXColumnMetrics` lives in `XLSX/Write` and the reader calls it rather than deriving its
    /// own. Two independent approximations of Excel's "characters of the normal font" unit would
    /// each be defensible and would disagree in the last decimal, so every save would nudge every
    /// column — and twenty saves later the sheet is visibly wrong. Rounding to whole pixels, which
    /// is what Excel itself does, is *also* not done here: it would be more faithful to Excel and
    /// would stop being its own inverse, which matters more.
    @Test(
        "characters → points → characters is a fixed point",
        arguments: [0.0, 1.0, 3.5, 8.43, 8.7109375, 12.0, 42.75, 255.0]
    )
    func roundTrips(characters: Double) {
        let points = XLSXColumnMetrics.points(fromCharacters: characters)
        #expect(
            abs(XLSXColumnMetrics.characters(fromPoints: points) - characters) < 1e-9,
            "\(characters) → \(points) pt → \(XLSXColumnMetrics.characters(fromPoints: points))"
        )
    }

    /// A hidden column is stored as `width="0"`, and that has to survive.
    @Test("a zero width round-trips as a zero width")
    func zeroWidthRoundTrips() {
        let points = XLSXColumnMetrics.points(fromCharacters: 0)
        #expect(XLSXColumnMetrics.characters(fromPoints: points) == 0)
    }
}
