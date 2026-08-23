import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// The failure mode this whole exercise exists to fix.
///
/// A workbook written by openpyxl, xlsxwriter or pandas ships `<f>SUM(…)</f>` with **no**
/// `<v>`. `staleCache` promises to keep the cached value; when there is none, keeping it means
/// showing an empty cell — which is indistinguishable from a cell that is genuinely blank. The
/// user sees nothing and has no reason to suspect anything is missing, which for a rendering
/// platform is the worst available outcome.
struct UncomputedCellTests {
    private static func recalculated(_ cells: [(String, Cell)]) -> Workbook {
        var workbook = GraphFixture.workbook(cells)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        return workbook
    }

    private static func cell(_ workbook: Workbook, _ address: String) -> Cell? {
        workbook[GraphFixture.sheetID]?.cells[CellRef(a1: address) ?? .origin]
    }

    @Test func anUnsupportedFunctionWithNoCachedValueRendersAsAnError() {
        let workbook = UncomputedCellTests.recalculated([("A1", .formula("MMULT(B1:B2,C1:C2)"))])
        let cell = UncomputedCellTests.cell(workbook, "A1")
        #expect(cell?.value == .error(.unknownName), "not blank — Excel's own token for a function it cannot resolve")
        #expect(cell?.flags.contains(.uncomputed) == true)
        #expect(cell?.flags.contains(.staleCache) == true)
    }

    @Test func anUnsupportedFunctionWithACachedValueStillKeepsIt() {
        // The promise `staleCache` was always making, and it is unchanged: when the producer
        // wrote a number, that number is what the user sees.
        let workbook = UncomputedCellTests.recalculated([
            ("A1", .formula("MMULT(B1:B2,C1:C2)", cached: .number(42))),
        ])
        let cell = UncomputedCellTests.cell(workbook, "A1")
        #expect(cell?.value == .number(42))
        #expect(cell?.flags.contains(.uncomputed) == false)
        #expect(cell?.flags.contains(.staleCache) == true)
    }

    @Test func theFlagIsStickyAcrossPassesRatherThanFlappingOnItsOwnPlaceholder() {
        // Pass two must not see the placeholder and conclude there was a cached value.
        var workbook = GraphFixture.workbook([("A1", .formula("MMULT(B1:B2,C1:C2)"))])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        let cell = UncomputedCellTests.cell(workbook, "A1")
        #expect(cell?.value == .error(.unknownName))
        #expect(cell?.flags.contains(.uncomputed) == true)
    }

    @Test func aCellThatBecomesComputableLosesTheFlagAndThePlaceholder() {
        var workbook = GraphFixture.workbook([("A1", .formula("MMULT(B1:B2,C1:C2)"))])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(UncomputedCellTests.cell(workbook, "A1")?.flags.contains(.uncomputed) == true)

        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            var cell = sheet.cells[CellRef(a1: "A1")!]!
            cell.formula = "1+1"
            try? sheet.cells.setCell(cell, at: CellRef(a1: "A1")!)
        }
        engine.rebuild(from: workbook)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        let cell = UncomputedCellTests.cell(workbook, "A1")
        #expect(cell?.value == .number(2))
        #expect(cell?.flags.contains(.uncomputed) == false)
        #expect(cell?.flags.contains(.staleCache) == false)
    }

    @Test func anExternalLinkWithNothingCachedSaysRefRatherThanName() {
        let workbook = UncomputedCellTests.recalculated([("A1", .formula("[1]Other!A1"))])
        #expect(UncomputedCellTests.cell(workbook, "A1")?.value == .error(.invalidReference))
        #expect(UncomputedCellTests.cell(workbook, "A1")?.flags.contains(.externalLink) == true)
    }

    @Test func aDownstreamCellWithNothingCachedIsAlsoVisiblyUncomputed() {
        let workbook = UncomputedCellTests.recalculated([
            ("A1", .formula("MMULT(D1:D2,E1:E2)")),
            ("B1", .formula("A1*2")),
        ])
        #expect(UncomputedCellTests.cell(workbook, "B1")?.value == .error(.unknownName))
        #expect(UncomputedCellTests.cell(workbook, "B1")?.flags.contains(.uncomputed) == true)
    }

    @Test func aTrulyEmptyCellIsStillEmpty() {
        // The other half of the distinction: nothing here invents a placeholder for a cell that
        // simply has no content.
        let workbook = UncomputedCellTests.recalculated([("A1", .number(1))])
        #expect(UncomputedCellTests.cell(workbook, "B9") == nil)
    }

    @Test func anUnknownFunctionIsAnErrorValueRatherThanAnAdmission() {
        // `#NAME?` from a typo is an *answer*, computed and storable; the placeholder is not.
        let workbook = UncomputedCellTests.recalculated([("A1", .formula("WOMBAT(1)"))])
        let cell = UncomputedCellTests.cell(workbook, "A1")
        #expect(cell?.value == .error(.unknownName))
        #expect(cell?.flags.contains(.uncomputed) == false, "we computed this: it really is #NAME?")
        #expect(cell?.flags.contains(.staleCache) == false)
    }
}
