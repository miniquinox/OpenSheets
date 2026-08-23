import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// `ReferenceTransform` is public API that A8 (paste, fill-down) and A9 (MCP row and column
/// insert) both build on, so it is tested as a table rather than by example: every rule gets a
/// row, and a change that breaks one shape without breaking the others shows up immediately.
struct ReferenceTransformTests {
    static let sheet = SheetID(1)
    static let other = SheetID(2)

    static var resolution: SheetResolution {
        SheetResolution(owner: sheet, identifiers: ["DATA": sheet, "OTHER": other])
    }

    // MARK: - Insert and delete

    struct Case: Sendable, CustomStringConvertible {
        var formula: String
        var edit: StructuralEdit
        var expected: String
        var note: String

        var description: String { "\(note): \(formula)" }
    }

    static let insertRowCases: [Case] = [
        Case(formula: "A5", edit: .insertRows(at: 0, count: 1, on: sheet), expected: "A6",
             note: "insert above a single cell pushes it down"),
        Case(formula: "A5", edit: .insertRows(at: 4, count: 1, on: sheet), expected: "A6",
             note: "insert exactly at the cell pushes it down"),
        Case(formula: "A5", edit: .insertRows(at: 5, count: 1, on: sheet), expected: "A5",
             note: "insert below the cell leaves it alone"),
        Case(formula: "A5", edit: .insertRows(at: 0, count: 3, on: sheet), expected: "A8",
             note: "a multi-row insert shifts by its count"),
        Case(formula: "$A$5", edit: .insertRows(at: 0, count: 1, on: sheet), expected: "$A$6",
             note: "an absolute reference shifts too — $ means 'do not move when copied', not 'never move'"),
        Case(formula: "A$5", edit: .insertRows(at: 0, count: 1, on: sheet), expected: "A$6",
             note: "a row-anchored reference shifts as well"),
        Case(formula: "SUM(A2:A5)", edit: .insertRows(at: 1, count: 1, on: sheet), expected: "SUM(A3:A6)",
             note: "insert at the top of a range moves the whole range"),
        Case(formula: "SUM(A2:A5)", edit: .insertRows(at: 2, count: 1, on: sheet), expected: "SUM(A2:A6)",
             note: "insert inside a range grows it"),
        Case(formula: "SUM(A2:A5)", edit: .insertRows(at: 5, count: 1, on: sheet), expected: "SUM(A2:A5)",
             note: "insert below a range leaves it alone"),
        Case(formula: "SUM(A2:A5)", edit: .insertRows(at: 0, count: 10, on: sheet), expected: "SUM(A12:A15)",
             note: "a big insert above a range"),
        Case(formula: "SUM(A:A)", edit: .insertRows(at: 5, count: 1, on: sheet), expected: "SUM(A:A)",
             note: "a whole-column reference already spans every row, so a row insert cannot change it"),
        Case(formula: "SUM(2:5)", edit: .insertRows(at: 0, count: 1, on: sheet), expected: "SUM(3:6)",
             note: "a whole-row reference shifts on a row insert"),
        Case(formula: "A5", edit: .insertRows(at: 0, count: 1, on: other), expected: "A5",
             note: "an edit on another sheet does not touch an unqualified reference"),
        Case(formula: "Other!A5", edit: .insertRows(at: 0, count: 1, on: other), expected: "Other!A6",
             note: "a qualified reference follows an edit on the sheet it names"),
        Case(formula: "Other!A5", edit: .insertRows(at: 0, count: 1, on: sheet), expected: "Other!A5",
             note: "and ignores an edit on a different one"),
        Case(formula: "SUM(A1:C3)", edit: .insertRows(at: 1, count: 1, on: sheet), expected: "SUM(A1:C4)",
             note: "a rectangle grows on the row axis only"),
        Case(formula: "A1+A5", edit: .insertRows(at: 2, count: 1, on: sheet), expected: "A1+A6",
             note: "each reference is adjusted independently"),
        Case(formula: "SUM(A1:A3)+SUM(A5:A7)", edit: .insertRows(at: 3, count: 1, on: sheet),
             expected: "SUM(A1:A3)+SUM(A6:A8)", note: "two ranges, one of them untouched"),
    ]

    static let insertColumnCases: [Case] = [
        Case(formula: "E1", edit: .insertColumns(at: 0, count: 1, on: sheet), expected: "F1",
             note: "insert left of a cell pushes it right"),
        Case(formula: "E1", edit: .insertColumns(at: 5, count: 1, on: sheet), expected: "E1",
             note: "insert right of a cell leaves it alone"),
        Case(formula: "$E$1", edit: .insertColumns(at: 0, count: 2, on: sheet), expected: "$G$1",
             note: "absolute columns shift too"),
        Case(formula: "SUM(B1:D1)", edit: .insertColumns(at: 2, count: 1, on: sheet), expected: "SUM(B1:E1)",
             note: "insert inside a range grows it"),
        Case(formula: "SUM(B1:D1)", edit: .insertColumns(at: 1, count: 1, on: sheet), expected: "SUM(C1:E1)",
             note: "insert at the left edge moves the range"),
        Case(formula: "SUM(1:1)", edit: .insertColumns(at: 3, count: 1, on: sheet), expected: "SUM(1:1)",
             note: "a whole-row reference is immune to a column insert"),
        Case(formula: "SUM(B:D)", edit: .insertColumns(at: 2, count: 1, on: sheet), expected: "SUM(B:E)",
             note: "a whole-column range grows on a column insert"),
        Case(formula: "SUM(A1:C3)", edit: .insertColumns(at: 1, count: 1, on: sheet), expected: "SUM(A1:D3)",
             note: "a rectangle grows on the column axis only"),
    ]

    static let deleteRowCases: [Case] = [
        Case(formula: "A5", edit: .deleteRows(at: 0, count: 1, on: sheet), expected: "A4",
             note: "delete above a cell pulls it up"),
        Case(formula: "A5", edit: .deleteRows(at: 4, count: 1, on: sheet), expected: "#REF!",
             note: "deleting the cell itself destroys the reference"),
        Case(formula: "A5", edit: .deleteRows(at: 5, count: 1, on: sheet), expected: "A5",
             note: "delete below leaves it alone"),
        Case(formula: "$A$5", edit: .deleteRows(at: 4, count: 1, on: sheet), expected: "#REF!",
             note: "anchoring does not save a deleted cell"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 1, count: 2, on: sheet), expected: "SUM(A2:A3)",
             note: "deleting the top of a range shrinks it"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 2, count: 1, on: sheet), expected: "SUM(A2:A4)",
             note: "deleting inside a range shrinks it"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 4, count: 4, on: sheet), expected: "SUM(A2:A4)",
             note: "deleting the bottom of a range shrinks it"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 1, count: 4, on: sheet), expected: "SUM(#REF!)",
             note: "deleting the whole range destroys the reference"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 0, count: 10, on: sheet), expected: "SUM(#REF!)",
             note: "deleting more than the whole range still destroys it"),
        Case(formula: "SUM(A2:A5)", edit: .deleteRows(at: 5, count: 1, on: sheet), expected: "SUM(A2:A5)",
             note: "deleting below a range leaves it alone"),
        Case(formula: "SUM(A:A)", edit: .deleteRows(at: 3, count: 5, on: sheet), expected: "SUM(A:A)",
             note: "a whole-column reference survives any row delete"),
        Case(formula: "SUM(2:5)", edit: .deleteRows(at: 1, count: 4, on: sheet), expected: "SUM(#REF!)",
             note: "a whole-row range can be deleted out of existence"),
        Case(formula: "Other!A5", edit: .deleteRows(at: 0, count: 1, on: other), expected: "Other!A4",
             note: "a cross-sheet delete"),
        Case(formula: "Other!A5", edit: .deleteRows(at: 4, count: 1, on: other), expected: "Other!#REF!",
             note: "a cross-sheet delete keeps the sheet name on the #REF!"),
        Case(formula: "A1+A5", edit: .deleteRows(at: 4, count: 1, on: sheet), expected: "A1+#REF!",
             note: "one reference breaks, the other does not"),
        Case(formula: "SUM(A1:C5)", edit: .deleteRows(at: 1, count: 2, on: sheet), expected: "SUM(A1:C3)",
             note: "a rectangle shrinks on the row axis"),
    ]

    static let deleteColumnCases: [Case] = [
        Case(formula: "E1", edit: .deleteColumns(at: 0, count: 1, on: sheet), expected: "D1",
             note: "delete left of a cell pulls it left"),
        Case(formula: "E1", edit: .deleteColumns(at: 4, count: 1, on: sheet), expected: "#REF!",
             note: "deleting the cell's column destroys the reference"),
        Case(formula: "SUM(B1:D1)", edit: .deleteColumns(at: 1, count: 1, on: sheet), expected: "SUM(B1:C1)",
             note: "deleting the left edge shrinks the range"),
        Case(formula: "SUM(B1:D1)", edit: .deleteColumns(at: 1, count: 3, on: sheet), expected: "SUM(#REF!)",
             note: "deleting the whole range destroys it"),
        Case(formula: "SUM(A:C)", edit: .deleteColumns(at: 1, count: 1, on: sheet), expected: "SUM(A:B)",
             note: "a whole-column range shrinks"),
        Case(formula: "SUM(A:A)", edit: .deleteColumns(at: 0, count: 1, on: sheet), expected: "SUM(#REF!)",
             note: "deleting the only column of a whole-column range destroys it"),
        Case(formula: "SUM(1:1)", edit: .deleteColumns(at: 3, count: 2, on: sheet), expected: "SUM(1:1)",
             note: "a whole-row reference survives any column delete"),
        Case(formula: "SUM(A1:C5)", edit: .deleteColumns(at: 0, count: 2, on: sheet), expected: "SUM(A1:A5)",
             note: "a rectangle shrinks on the column axis"),
    ]

    static var structuralCases: [Case] {
        insertRowCases + insertColumnCases + deleteRowCases + deleteColumnCases
    }

    @Test(arguments: ReferenceTransformTests.structuralCases)
    func structuralEditsRewriteReferences(_ testCase: Case) throws {
        let result = try ReferenceTransform.adjust(
            formula: testCase.formula, for: testCase.edit, resolving: ReferenceTransformTests.resolution
        )
        #expect(result.formula == testCase.expected, "\(testCase.note): got \(result.formula)")
    }

    @Test func structuralSuiteIsBigEnough() {
        #expect(ReferenceTransformTests.structuralCases.count + ReferenceTransformTests.translateCases.count >= 60)
    }

    // MARK: - Copy and fill

    struct TranslateCase: Sendable, CustomStringConvertible {
        var formula: String
        var from: CellRef
        var to: CellRef
        var expected: String
        var note: String

        var description: String { "\(note): \(formula)" }
    }

    static let translateCases: [TranslateCase] = [
        TranslateCase(formula: "A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "A2", note: "fill down moves a relative row"),
        TranslateCase(formula: "A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 0, column: 1),
                      expected: "B1", note: "fill right moves a relative column"),
        TranslateCase(formula: "A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 4, column: 3),
                      expected: "D5", note: "a diagonal copy moves both axes"),
        TranslateCase(formula: "$A$1", from: CellRef(row: 0, column: 0), to: CellRef(row: 4, column: 3),
                      expected: "$A$1", note: "a fully absolute reference does not move"),
        TranslateCase(formula: "$A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 4, column: 3),
                      expected: "$A5", note: "a column-anchored reference moves only down"),
        TranslateCase(formula: "A$1", from: CellRef(row: 0, column: 0), to: CellRef(row: 4, column: 3),
                      expected: "D$1", note: "a row-anchored reference moves only across"),
        TranslateCase(formula: "SUM(A1:A3)", from: CellRef(row: 0, column: 1), to: CellRef(row: 0, column: 2),
                      expected: "SUM(B1:B3)", note: "a range moves as a whole"),
        TranslateCase(formula: "SUM($A$1:$A$3)", from: CellRef(row: 0, column: 1), to: CellRef(row: 0, column: 2),
                      expected: "SUM($A$1:$A$3)", note: "an absolute range does not move"),
        TranslateCase(formula: "SUM(A1:$A$3)", from: CellRef(row: 0, column: 1), to: CellRef(row: 1, column: 1),
                      expected: "SUM(A2:$A$3)", note: "half-anchored ranges move one corner"),
        TranslateCase(formula: "A1", from: CellRef(row: 1, column: 1), to: CellRef(row: 0, column: 0),
                      expected: "#REF!", note: "copying up and left off the grid is #REF!"),
        TranslateCase(formula: "A1+$B$2", from: CellRef(row: 0, column: 0), to: CellRef(row: 2, column: 0),
                      expected: "A3+$B$2", note: "mixed anchoring inside one formula"),
        TranslateCase(formula: "Other!A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "Other!A2", note: "a cross-sheet relative reference still moves"),
        TranslateCase(formula: "SUM(A:A)", from: CellRef(row: 0, column: 0), to: CellRef(row: 5, column: 1),
                      expected: "SUM(B:B)", note: "a whole-column reference moves across but not down"),
        TranslateCase(formula: "SUM(1:1)", from: CellRef(row: 0, column: 0), to: CellRef(row: 5, column: 1),
                      expected: "SUM(6:6)", note: "a whole-row reference moves down but not across"),
        TranslateCase(formula: "A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 0, column: 0),
                      expected: "A1", note: "copying to the same place changes nothing"),
        TranslateCase(formula: "SUM(A1:A3)*2+B1", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "SUM(A2:A4)*2+B2", note: "every reference in a compound formula moves"),
        TranslateCase(formula: "IF(A1>0,B1,C1)", from: CellRef(row: 0, column: 0), to: CellRef(row: 3, column: 0),
                      expected: "IF(A4>0,B4,C4)", note: "references inside a call move"),
        TranslateCase(formula: "#REF!", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "#REF!", note: "an already-broken reference stays broken"),
        TranslateCase(formula: "'My Sheet'!A1", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "'My Sheet'!A2", note: "quoting survives a translation"),
        TranslateCase(formula: "A1048576", from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0),
                      expected: "#REF!", note: "copying off the bottom of the grid is #REF!"),
        TranslateCase(formula: "XFD1", from: CellRef(row: 0, column: 0), to: CellRef(row: 0, column: 1),
                      expected: "#REF!", note: "copying off the right of the grid is #REF!"),
    ]

    @Test(arguments: ReferenceTransformTests.translateCases)
    func copyingAFormulaTranslatesItsRelativeReferences(_ testCase: TranslateCase) throws {
        let result = try ReferenceTransform.translate(
            formula: testCase.formula, from: testCase.from, to: testCase.to
        )
        #expect(result.formula == testCase.expected, "\(testCase.note): got \(result.formula)")
    }

    // MARK: - Reporting

    @Test func reportsHowManyReferencesTheEditDestroyed() throws {
        let result = try ReferenceTransform.adjust(
            formula: "A5+B5+C6",
            for: .deleteRows(at: 4, count: 1, on: ReferenceTransformTests.sheet),
            resolving: ReferenceTransformTests.resolution
        )
        #expect(result.invalidatedReferences == 2)
        // C6 is below the deleted row, so it survives and moves up to C5.
        #expect(result.formula == "#REF!+#REF!+C5")
        #expect(result.didChange)
    }

    @Test func reportsWhenNothingChanged() throws {
        let result = try ReferenceTransform.adjust(
            formula: "A1+A2",
            for: .insertRows(at: 10, count: 1, on: ReferenceTransformTests.sheet),
            resolving: ReferenceTransformTests.resolution
        )
        #expect(!result.didChange)
        #expect(result.invalidatedReferences == 0)
    }

    // MARK: - Plain rectangles

    @Test func adjustsAPlainRangeForDefinedNamesAndMerges() {
        let sheet = ReferenceTransformTests.sheet
        let range = CellRange(a1: "B2:D5") ?? .entireSheet
        #expect(
            ReferenceTransform.adjust(range, on: sheet, for: .insertRows(at: 0, count: 2, on: sheet))?.a1String
                == "B4:D7"
        )
        #expect(
            ReferenceTransform.adjust(range, on: sheet, for: .deleteRows(at: 1, count: 4, on: sheet)) == nil,
            "a range whose every row is deleted has no rectangle left"
        )
        #expect(
            ReferenceTransform.adjust(range, on: SheetID(9), for: .insertRows(at: 0, count: 2, on: sheet))?.a1String
                == "B2:D5",
            "an edit on another sheet leaves the rectangle alone"
        )
    }

    // MARK: - Cut and paste

    @Test func referencesInsideAMovedBlockFollowIt() throws {
        let sheet = ReferenceTransformTests.sheet
        let moved = SheetRange(sheet: sheet, range: CellRange(a1: "A1:B2") ?? .entireSheet)
        let result = try ReferenceTransform.move(
            formula: "A1+C5", movedRange: moved, rowDelta: 10, columnDelta: 0,
            resolving: ReferenceTransformTests.resolution
        )
        #expect(result.formula == "A11+C5")
    }

    @Test func aMoveOffTheGridBreaksTheReference() throws {
        let sheet = ReferenceTransformTests.sheet
        let moved = SheetRange(sheet: sheet, range: CellRange(a1: "A1:B2") ?? .entireSheet)
        let result = try ReferenceTransform.move(
            formula: "A1", movedRange: moved, rowDelta: -1, columnDelta: 0,
            resolving: ReferenceTransformTests.resolution
        )
        #expect(result.formula == "#REF!")
    }

    // MARK: - Anchoring

    @Test func anchoringCyclesThroughExcelsFourStates() throws {
        var reference = FormulaReference(a1Text: "A1") ?? FormulaReference(.origin)
        let spellings = (0 ..< 5).map { _ -> String in
            reference = ReferenceTransform.cycleAnchoring(reference)
            return reference.a1Text
        }
        #expect(spellings == ["$A$1", "A$1", "$A1", "A1", "$A$1"])
    }

    // MARK: - Storage spelling

    @Test func aTransformedFormulaKeepsItsStorageSpelling() throws {
        let result = try ReferenceTransform.translate(
            formula: "_xlfn.XLOOKUP(A1,B1:B9,C1:C9)",
            from: CellRef(row: 0, column: 0), to: CellRef(row: 1, column: 0)
        )
        #expect(result.formula == "_xlfn.XLOOKUP(A2,B2:B10,C2:C10)")
    }
}
