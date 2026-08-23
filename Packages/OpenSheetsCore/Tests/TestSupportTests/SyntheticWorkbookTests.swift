import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("SyntheticWorkbook")
struct SyntheticWorkbookTests {
    @Test("the same arguments produce the same workbook, twice")
    func determinism() throws {
        let first = try SyntheticWorkbook.generate(rows: 40, cols: 12)
        let second = try SyntheticWorkbook.generate(rows: 40, cols: 12)
        #expect(first == second, "a benchmark whose input changes every run is not a benchmark")
    }

    @Test("SplitMix64 produces a fixed stream")
    func generatorIsStable() {
        var random = SplitMix64(seed: 1)
        let drawn = (0 ..< 4).map { _ in random.next() }
        var again = SplitMix64(seed: 1)
        #expect(drawn == (0 ..< 4).map { _ in again.next() })

        var different = SplitMix64(seed: 2)
        #expect(drawn[0] != different.next())
    }

    @Test("the realistic shape hits its declared proportions exactly")
    func shapeProportions() throws {
        // 100 × 10 = 1000 ordinals. Periods are exact, not probabilistic, so these are
        // arithmetic rather than statistical.
        let sheet = try SyntheticWorkbook.sheet(rows: 100, cols: 10)
        var blanks = 0
        var formulas = 0
        var text = 0
        for row in 0 ..< 100 {
            for column in 0 ..< 10 {
                guard let cell = sheet.cells[CellRef(row: row, column: column)] else {
                    blanks += 1
                    continue
                }
                if cell.isFormula { formulas += 1 }
                if cell.value.text != nil { text += 1 }
            }
        }
        // blankEvery: 23 over 1000 ordinals.
        #expect(blanks == 1000 / 23 + 1)
        #expect(formulas > 0)
        #expect(text > 0)
        #expect(sheet.cells.count == 1000 - blanks)
    }

    @Test("numbersOnly is dense, has no formulas, and uses one style")
    func numbersOnlyShape() throws {
        let store = try SyntheticWorkbook.cellStore(rows: 20, cols: 20, shape: .numbersOnly)
        #expect(store.count == 400)
        store.forEachCell(in: .entireSheet) { _, cell in
            #expect(cell.formula == nil)
            #expect(cell.value.number != nil)
            #expect(cell.styleID == .default)
        }
    }

    @Test("a zero-sized request is empty rather than an error")
    func degenerateSizes() throws {
        #expect(try SyntheticWorkbook.cellStore(rows: 0, cols: 10).isEmpty)
        #expect(try SyntheticWorkbook.cellStore(rows: 10, cols: 0).isEmpty)
    }

    @Test("multi-sheet generation gives each sheet different content")
    func multipleSheets() throws {
        let workbook = try SyntheticWorkbook.generate(sheets: 3, rows: 10, cols: 5)
        #expect(workbook.sheets.map(\.name) == ["Sheet1", "Sheet2", "Sheet3"])
        #expect(workbook.sheets[0].cells != workbook.sheets[1].cells)
    }

    @Test("sparse scatters cells across the whole grid, not into a corner")
    func sparseIsSparse() throws {
        let workbook = try SyntheticWorkbook.sparse(cellCount: 500, seed: 7)
        let sheet = workbook.sheets[0]
        #expect(sheet.cells.count == 500)
        let used = try #require(sheet.usedRange)
        // 500 uniform draws over a million rows: the bounding box should cover most of the
        // sheet. Anything compact would mean the generator collapsed.
        #expect(used.rowCount > Limits.rowCount / 2)
        #expect(used.columnCount > Limits.columnCount / 2)
    }

    @Test("CSV generation matches the requested shape")
    func csvGeneration() {
        let text = SyntheticWorkbook.csv(rows: 5, cols: 3)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 5)
        #expect(lines[0] == "col0,col1,col2")
        for line in lines {
            #expect(line.split(separator: ",", omittingEmptySubsequences: false).count == 3)
        }
    }

    @Test("perturb changes only the cells it says it changed")
    func perturbation() throws {
        let original = try SyntheticWorkbook.generate(rows: 50, cols: 20, shape: .numbersOnly)
        let changed = try SyntheticWorkbook.perturb(original, changedCells: 25, seed: 3)

        var differences = 0
        let sheet = original.sheets[0]
        let other = changed.sheets[0]
        for row in 0 ..< 50 {
            for column in 0 ..< 20 {
                let ref = CellRef(row: row, column: column)
                if sheet.cells[ref] != other.cells[ref] { differences += 1 }
            }
        }
        // At most 25: the generator may pick the same cell twice, and may pick a value that
        // happens to equal the one already there.
        #expect(differences > 0)
        #expect(differences <= 25)
        #expect(other.cells.count == sheet.cells.count)
    }

    @Test("perturbing with zero changes is a no-op")
    func perturbNothing() throws {
        let original = try SyntheticWorkbook.generate(rows: 10, cols: 10, shape: .numbersOnly)
        #expect(try SyntheticWorkbook.perturb(original, changedCells: 0) == original)
    }
}
