import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// Dynamic-array spilling: where the result goes, what stops it, and what happens when it
/// changes size.
///
/// Every expectation here is a property of the *sheet after applying the pass*, not of the
/// returned `RecalcResult` alone. The result is a description of an intent; the bug that
/// matters is the one where the intent is right and the sheet ends up wrong.
struct SpillTests {
    private static func recalculated(_ cells: [(String, Cell)]) -> (Workbook, RecalcResult) {
        var workbook = GraphFixture.workbook(cells)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        result.apply(to: &workbook)
        return (workbook, result)
    }

    private static func value(_ workbook: Workbook, _ address: String) -> CellValue {
        workbook[GraphFixture.sheetID]?.cells[CellRef(a1: address) ?? .origin]?.value ?? .empty
    }

    private static func flags(_ workbook: Workbook, _ address: String) -> CellFlags {
        workbook[GraphFixture.sheetID]?.cells[CellRef(a1: address) ?? .origin]?.flags ?? []
    }

    // MARK: - Placement

    @Test func aRowResultOccupiesTheCellsToItsRight() {
        let (workbook, result) = SpillTests.recalculated([("A1", .formula("SEQUENCE(1,3)"))])
        #expect(result.spills[GraphFixture.cell("A1")] == CellRange(a1: "A1:C1"))
        #expect(SpillTests.value(workbook, "A1") == .number(1))
        #expect(SpillTests.value(workbook, "B1") == .number(2))
        #expect(SpillTests.value(workbook, "C1") == .number(3))
    }

    @Test func aColumnResultOccupiesTheCellsBelowIt() {
        let (workbook, _) = SpillTests.recalculated([("B2", .formula("SEQUENCE(3)"))])
        #expect(SpillTests.value(workbook, "B2") == .number(1))
        #expect(SpillTests.value(workbook, "B3") == .number(2))
        #expect(SpillTests.value(workbook, "B4") == .number(3))
    }

    @Test func aTwoDimensionalResultFillsARectangle() {
        let (workbook, result) = SpillTests.recalculated([("A1", .formula("SEQUENCE(2,3)"))])
        #expect(result.spills[GraphFixture.cell("A1")] == CellRange(a1: "A1:C2"))
        #expect(SpillTests.value(workbook, "C2") == .number(6))
    }

    @Test func theAnchorHoldsTheFormulaAndTheSpilledCellsDoNot() {
        let (workbook, _) = SpillTests.recalculated([("A1", .formula("SEQUENCE(1,3)"))])
        let sheet = workbook[GraphFixture.sheetID]!
        #expect(sheet.cells[CellRef(a1: "A1")!]?.formula == "SEQUENCE(1,3)")
        #expect(sheet.cells[CellRef(a1: "B1")!]?.formula == nil)
        #expect(sheet.cells[CellRef(a1: "C1")!]?.formula == nil)
    }

    @Test func theRegionIsRecordedOnTheSheetSoAWriterAndAnEditorCanSeeIt() {
        let (workbook, _) = SpillTests.recalculated([("A1", .formula("SEQUENCE(1,3)"))])
        let sheet = workbook[GraphFixture.sheetID]!
        #expect(sheet.arrayFormulaRanges[CellRef(a1: "A1")!] == CellRange(a1: "A1:C1"))
        #expect(sheet.spillOwner(of: CellRef(a1: "B1")!)?.anchor == CellRef(a1: "A1"))
        #expect(sheet.spillOwner(of: CellRef(a1: "B1")!)?.isDynamic == true)
        #expect(sheet.isSpilledInto(CellRef(a1: "B1")!))
        #expect(!sheet.isSpilledInto(CellRef(a1: "A1")!), "the anchor is not spilled into")
        #expect(!sheet.isSpilledInto(CellRef(a1: "D1")!))
    }

    @Test func theAnchorAndItsCellsCarryTheFlagsThatDescribeThem() {
        let (workbook, _) = SpillTests.recalculated([("A1", .formula("SEQUENCE(1,2)"))])
        #expect(SpillTests.flags(workbook, "A1").contains(.spillAnchor))
        #expect(!SpillTests.flags(workbook, "A1").contains(.spilledInto))
        #expect(SpillTests.flags(workbook, "B1").contains(.spilledInto))
        #expect(!SpillTests.flags(workbook, "B1").contains(.spillAnchor))
    }

    @Test func aOneByOneResultIsAnOrdinaryValueRatherThanASpill() {
        let (workbook, result) = SpillTests.recalculated([("A1", .formula("SEQUENCE(1,1)"))])
        #expect(result.spills.isEmpty)
        #expect(SpillTests.value(workbook, "A1") == .number(1))
        #expect(!SpillTests.flags(workbook, "A1").contains(.spillAnchor))
    }

    @Test func aBareRangeStillReducesByImplicitIntersectionRatherThanSpilling() {
        // A deliberate divergence from Excel 365, documented on `FormulaEngine.place`: files
        // that put a bare multi-cell reference in a cell are old ones that meant intersection.
        let (workbook, result) = SpillTests.recalculated([
            ("A1", .number(10)), ("A2", .number(20)), ("A3", .number(30)),
            ("C2", .formula("A1:A3")),
        ])
        #expect(result.spills.isEmpty)
        #expect(SpillTests.value(workbook, "C2") == .number(20), "row 2 of the range, from row 2")
        #expect(SpillTests.value(workbook, "C3") == .empty)
    }

    // MARK: - #SPILL!

    @Test func aValueInTheWayIsSpillNotAnOverwrite() {
        let (workbook, result) = SpillTests.recalculated([
            ("A1", .formula("SEQUENCE(1,3)")),
            ("B1", .number(99)),
        ])
        #expect(result.spills.isEmpty)
        #expect(SpillTests.value(workbook, "A1") == .error(.spill))
        #expect(SpillTests.value(workbook, "B1") == .number(99), "the blocker is left alone")
    }

    @Test func aFormulaInTheWayAlsoBlocks() {
        let (workbook, _) = SpillTests.recalculated([
            ("A1", .formula("SEQUENCE(3)")),
            ("A3", .formula("1+1")),
        ])
        #expect(SpillTests.value(workbook, "A1") == .error(.spill))
        #expect(SpillTests.value(workbook, "A3") == .number(2))
    }

    @Test func aBlankButStyledCellDoesNotBlock() {
        // A whole column formatted as currency is empty cells with a style. Treating those as
        // content would make `#SPILL!` fire on every real sheet.
        var workbook = GraphFixture.workbook([("A1", .formula("SEQUENCE(1,2)"))])
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try? sheet.cells.setCell(Cell.styled(StyleID(rawValue: 3)), at: CellRef(a1: "B1")!)
        }
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        result.apply(to: &workbook)
        #expect(SpillTests.value(workbook, "A1") == .number(1))
        #expect(SpillTests.value(workbook, "B1") == .number(2))
    }

    @Test func aMergedRegionInTheWayBlocks() {
        var workbook = GraphFixture.workbook([("A1", .formula("SEQUENCE(1,3)"))])
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            sheet.merges = [CellRange(a1: "B1:B2")!]
        }
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        result.apply(to: &workbook)
        #expect(SpillTests.value(workbook, "A1") == .error(.spill))
    }

    @Test func aResultThatWouldRunOffTheSheetIsSpill() {
        let (workbook, _) = SpillTests.recalculated([("XFC1", .formula("SEQUENCE(1,5)"))])
        #expect(SpillTests.value(workbook, "XFC1") == .error(.spill))
    }

    @Test func twoAnchorsCompetingForTheSameCellsGiveTheSecondOneSpill() {
        let (workbook, _) = SpillTests.recalculated([
            ("A1", .formula("SEQUENCE(1,3)")),
            ("A2", .formula("SEQUENCE(1,3)")),
            ("B2", .number(1)),
        ])
        #expect(SpillTests.value(workbook, "A1") == .number(1))
        #expect(SpillTests.value(workbook, "A2") == .error(.spill))
    }

    @Test func aBlockedSpillThatBecomesUnblockedSpillsOnTheNextPass() throws {
        var workbook = GraphFixture.workbook([
            ("A1", .formula("SEQUENCE(1,3)")),
            ("B1", .number(99)),
        ])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "A1") == .error(.spill))

        // `try`, not `try?`: if clearing the blocker fails, the rest of this test is asserting
        // against a workbook that never changed, and it would pass for the wrong reason.
        _ = try workbook.withSheet(GraphFixture.sheetID) { sheet in
            sheet.cells.removeCell(at: CellRef(a1: "B1")!)
        }
        engine.rebuild(from: workbook)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "A1") == .number(1))
        #expect(SpillTests.value(workbook, "C1") == .number(3))
    }

    // MARK: - Resizing

    @Test func aSpillThatShrinksClearsTheCellsItNoLongerCovers() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(4)),
            ("C1", .formula("SEQUENCE(A1)")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "C4") == .number(4))

        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try? sheet.cells.setCell(.number(2), at: CellRef(a1: "A1")!)
        }
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        result.apply(to: &workbook)

        #expect(SpillTests.value(workbook, "C1") == .number(1))
        #expect(SpillTests.value(workbook, "C2") == .number(2))
        #expect(SpillTests.value(workbook, "C3") == .empty, "the old tail must not be left behind")
        #expect(SpillTests.value(workbook, "C4") == .empty)
        #expect(workbook[GraphFixture.sheetID]?.arrayFormulaRanges[CellRef(a1: "C1")!] == CellRange(a1: "C1:C2"))
    }

    @Test func aSpillThatGrowsCoversTheNewCells() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(2)),
            ("C1", .formula("SEQUENCE(A1)")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try? sheet.cells.setCell(.number(4), at: CellRef(a1: "A1")!)
        }
        engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")]).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "C4") == .number(4))
    }

    @Test func aFormulaThatStopsReturningAnArrayClearsItsOldRegion() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(3)),
            ("C1", .formula("IF(A1>2,SEQUENCE(3),7)")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "C3") == .number(3))

        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try? sheet.cells.setCell(.number(1), at: CellRef(a1: "A1")!)
        }
        engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")]).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "C1") == .number(7))
        #expect(SpillTests.value(workbook, "C2") == .empty)
        #expect(SpillTests.value(workbook, "C3") == .empty)
        #expect(workbook[GraphFixture.sheetID]?.arrayFormulaRanges[CellRef(a1: "C1")!] == nil)
    }

    @Test func clearingASpilledCellLeavesItsFormattingBehind() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(3)),
            ("C1", .formula("SEQUENCE(A1)")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            var styled = sheet.cells[CellRef(a1: "C3")!] ?? Cell()
            styled.styleID = StyleID(rawValue: 5)
            try? sheet.cells.setCell(styled, at: CellRef(a1: "C3")!)
            try? sheet.cells.setCell(.number(1), at: CellRef(a1: "A1")!)
        }
        engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")]).apply(to: &workbook)
        let cleared = workbook[GraphFixture.sheetID]?.cells[CellRef(a1: "C3")!]
        #expect(cleared?.value == .empty)
        #expect(cleared?.styleID == StyleID(rawValue: 5), "the user's formatting is not the formula's to delete")
    }

    @Test func aFormulaWeCannotEvaluateKeepsItsCachedRegionRatherThanClearingIt() {
        // The trap: an unsupported anchor has no computed shape, so "clear the old region" has
        // nothing to replace it with — and would delete the cached values of an array formula
        // we merely failed to re-evaluate. `staleCache`'s promise applies to the whole region.
        var workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("C1", .formula("MMULT(A1:A2,B1:B2)+A1", cached: .number(7))),
            ("C2", Cell(value: .number(8), flags: .arrayFormula)),
        ])
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            sheet.arrayFormulaRanges[CellRef(a1: "C1")!] = CellRange(a1: "C1:C2")!
        }
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        result.apply(to: &workbook)

        #expect(result.stale[GraphFixture.cell("C1")] != nil)
        #expect(SpillTests.value(workbook, "C1") == .number(7), "the cached anchor value survives")
        #expect(SpillTests.value(workbook, "C2") == .number(8), "and so does the rest of the region")
        #expect(workbook[GraphFixture.sheetID]?.arrayFormulaRanges[CellRef(a1: "C1")!] == CellRange(a1: "C1:C2"))
    }

    // MARK: - Dependencies through a spill

    @Test func aFormulaReadingASpilledCellIsRecalculatedWhenTheAnchorChanges() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("C1", .formula("SEQUENCE(3,1,A1)")),
            ("E1", .formula("C3*10")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "E1") == .number(30))

        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try? sheet.cells.setCell(.number(10), at: CellRef(a1: "A1")!)
        }
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        result.apply(to: &workbook)
        #expect(result.visited.contains(GraphFixture.cell("E1")), "a reader of a spilled cell must be visited")
        #expect(SpillTests.value(workbook, "E1") == .number(120), "10, 11, 12 — so C3 is 12")
    }

    @Test func aReaderOfASpilledCellIsOrderedAfterTheAnchor() {
        // The reader must see this pass's value, not the previous one. Ordering, not luck.
        var workbook = GraphFixture.workbook([
            ("C1", .formula("SEQUENCE(2,1,5)")),
            ("A1", .formula("C2+1")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(SpillTests.value(workbook, "A1") == .number(7))
    }
}
