import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("WorkbookBuilder")
struct WorkbookBuilderTests {
    @Test("the one-liner from the brief builds what it says")
    func fluentChain() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 42)
            .formula("B1", "A1*2", cached: 84)
            .sheet("Notes")
            .cell("A1", "hello")
            .build()

        #expect(workbook.sheets.map(\.name) == ["Data", "Notes"])
        let data = try #require(workbook.sheet(named: "Data"))
        #expect(data.cells[CellRef(row: 0, column: 0)]?.value == .number(42))
        let formulaCell = try #require(data.cells[CellRef(row: 0, column: 1)])
        #expect(formulaCell.formula == "A1*2")
        #expect(formulaCell.value == .number(84))
        #expect(workbook.sheet(named: "Notes")?.cells[.origin]?.value == .text("hello"))
    }

    @Test("a cell with no sheet named first lands on an implicit Sheet1")
    func implicitSheet() throws {
        let workbook = try WorkbookBuilder().cell("A1", 1).build()
        #expect(workbook.sheets.count == 1)
        #expect(workbook.sheets[0].name == "Sheet1")
        #expect(workbook.sheets[0].cells[.origin]?.value == .number(1))
    }

    @Test("naming the same sheet twice comes back to it rather than duplicating it")
    func reselectingASheet() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1)
            .sheet("Other").cell("A1", 2)
            .sheet("Data").cell("B1", 3)
            .build()

        #expect(workbook.sheets.count == 2)
        let data = try #require(workbook.sheet(named: "Data"))
        #expect(data.cells[CellRef(row: 0, column: 0)]?.value == .number(1))
        #expect(data.cells[CellRef(row: 0, column: 1)]?.value == .number(3))
    }

    @Test("the builder is a value type, so a shared prefix does not leak between branches")
    func valueSemantics() throws {
        let base = WorkbookBuilder().sheet("Data").cell("A1", 1)
        let left = try base.cell("B1", 2).build()
        let right = try base.cell("B1", 99).build()

        #expect(left.sheets[0].cells[CellRef(row: 0, column: 1)]?.value == .number(2))
        #expect(right.sheets[0].cells[CellRef(row: 0, column: 1)]?.value == .number(99))
    }

    @Test("a bad A1 address is deferred to build() rather than crashing the chain")
    func deferredError() {
        let builder = WorkbookBuilder().sheet("Data").cell("not-a-ref", 1).cell("A1", 2)
        #expect(builder.pendingError?.code == "ref.invalid")
        #expect(throws: SheetError.self) { try builder.build() }
    }

    @Test("the first failure wins, so the message names the real cause")
    func firstFailureWins() {
        let builder = WorkbookBuilder()
            .sheet("Data")
            .cell("zzz1", 1) // first
            .cell("also-bad", 2) // second, must not overwrite
        #expect(builder.pendingError?.code == "ref.invalid")
        if case let .invalidCellReference(text) = builder.pendingError {
            #expect(text == "zzz1")
        } else {
            Issue.record("expected invalidCellReference, got \(String(describing: builder.pendingError))")
        }
    }

    @Test("an illegal sheet name is caught at the point it is named")
    func illegalSheetName() {
        let builder = WorkbookBuilder().sheet("has/a/slash")
        #expect(builder.pendingError?.code == "sheet.invalidName")
    }

    @Test("build() validates, buildWithoutValidating() does not")
    func validationOnBuild() throws {
        let overlapping = WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1)
            .merge("A1:C3")
            .merge("B2:D4")

        #expect(throws: SheetError.self) { try overlapping.build() }
        let unvalidated = try overlapping.buildWithoutValidating()
        #expect(unvalidated.sheets[0].merges.count == 2)
    }

    @Test("rows and fills write rectangles")
    func rectangles() throws {
        let sheet = try WorkbookBuilder()
            .sheet("Grid")
            .row("A1", [1, 2, 3])
            .rows("A2", [[4, 5], [6, 7]])
            .fill("E1:F2", with: .text("x"))
            .buildSheet()

        #expect(sheet.cells[CellRef(row: 0, column: 2)]?.value == .number(3))
        #expect(sheet.cells[CellRef(row: 2, column: 1)]?.value == .number(7))
        #expect(sheet.cells[CellRef(row: 1, column: 5)]?.value == .text("x"))
        #expect(sheet.cells.count == 3 + 4 + 4)
    }

    @Test("a merge widens the used range past the cells that hold values")
    func mergeWidensUsedRange() throws {
        // Wave 1 addendum §5, the merged-cells fixture in miniature.
        let sheet = try WorkbookBuilder()
            .sheet("Merged")
            .cell("A1", "title")
            .merge("A1:D1")
            .buildSheet()

        #expect(sheet.usedRange?.a1String == "A1")
        #expect(WorkbookMatcher.mergeAwareUsedRange(sheet)?.a1String(collapseSingleCell: false) == "A1:D1")
    }

    @Test("column styling widens formattedExtent without adding cells")
    func columnStyleExtent() throws {
        let sheet = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1)
            .columnStyle(CellStyle(numberFormatID: 44), columns: 3 ... 3)
            .buildSheet()

        #expect(sheet.cells.count == 1)
        #expect(sheet.usedRange?.a1String == "A1")
        #expect(sheet.formattedExtent?.end.column == 3)
    }

    @Test("styles are interned into the workbook table, not invented per cell")
    func styleInterning() throws {
        let currency = CellStyle(numberFormatID: 44)
        let workbook = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1).style("A1", currency)
            .cell("A2", 2).style("A2", currency)
            .build()

        let first = try #require(workbook.sheets[0].cells[CellRef(row: 0, column: 0)])
        let second = try #require(workbook.sheets[0].cells[CellRef(row: 1, column: 0)])
        #expect(first.styleID == second.styleID)
        #expect(first.styleID != .default)
        #expect(workbook.styles.count == 2) // default plus the interned one
    }

    @Test("fragments, hyperlinks and passthrough entries all survive to the workbook")
    func passthroughAndFragments() throws {
        let xml = "<drawing r:id=\"rId1\"/>"
        let workbook = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1)
            .fragment("drawing", xml: xml)
            .hyperlink("A1", target: "https://example.invalid/never-fetched")
            .passthroughPart(path: "xl/drawings/drawing1.xml", contents: Data("<xdr/>".utf8))
            .build()

        let sheet = workbook.sheets[0]
        #expect(sheet.sheetLevelFragments.first(named: "drawing")?.xml == xml)
        #expect(sheet.hyperlinks[.origin]?.target == "https://example.invalid/never-fetched")
        #expect(sheet.cells[.origin]?.flags.contains(.hyperlink) == true)
        #expect(workbook.passthrough["xl/drawings/drawing1.xml"] != nil)
    }

    @Test("a defined name resolves its sheet when the sheet already exists")
    func definedNames() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Budget")
            .cell("A1", 1)
            .definedName("Revenue", refersTo: "Budget!$A$1:$A$3")
            .build()

        let name = try #require(workbook.definedName("Revenue"))
        #expect(name.formula == "Budget!$A$1:$A$3")
        #expect(name.target?.sheet == workbook.sheets[0].id)
        #expect(name.target?.range.a1String(collapseSingleCell: false) == "A1:A3")
    }

    @Test("a defined name that looks like a cell reference is rejected")
    func invalidDefinedName() {
        let builder = WorkbookBuilder().sheet("Data").definedName("A1", refersTo: "Data!$A$1")
        #expect(builder.pendingError?.code == "name.invalid")
    }

    @Test("the date system and read-only reason land in the metadata")
    func metadata() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1)
            .dateSystem(.excel1904)
            .readOnly(.fileSystemPermissions)
            .meta { $0.application = "TestSupportTests" }
            .build()

        #expect(workbook.meta.dateSystem == .excel1904)
        #expect(workbook.meta.readOnlyReason == .fileSystemPermissions)
        #expect(workbook.meta.isWritable == false)
        #expect(workbook.meta.application == "TestSupportTests")
    }

    @Test("clear removes a cell rather than emptying it")
    func clearing() throws {
        let sheet = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1)
            .cell("A2", 2)
            .clear("A1")
            .buildSheet()

        #expect(sheet.cells[.origin] == nil)
        #expect(sheet.cells.count == 1)
    }
}
