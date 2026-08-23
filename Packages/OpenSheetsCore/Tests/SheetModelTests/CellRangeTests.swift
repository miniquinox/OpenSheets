@testable import SheetModel
import Testing

@Suite("CellRange")
struct CellRangeTests {
    @Test("the initialiser normalises whichever corners you hand it")
    func normalisation() {
        let downward = CellRange(start: CellRef(row: 0, column: 0), end: CellRef(row: 4, column: 1))
        let upward = CellRange(start: CellRef(row: 4, column: 1), end: CellRef(row: 0, column: 0))
        let mixed = CellRange(start: CellRef(row: 4, column: 0), end: CellRef(row: 0, column: 1))
        #expect(downward == upward)
        #expect(downward == mixed)
        #expect(downward.start == .origin)
        #expect(downward.end == CellRef(row: 4, column: 1))
    }

    @Test("geometry counts inclusive corners")
    func geometry() throws {
        let range = try #require(CellRange(a1: "B2:D5"))
        #expect(range.rowCount == 4)
        #expect(range.columnCount == 3)
        #expect(range.cellCount == 12)
        #expect(!range.isSingleCell)
        #expect(CellRange(CellRef.origin).isSingleCell)
        #expect(CellRange(CellRef.origin).cellCount == 1)
    }

    @Test("A1 parsing accepts a pair or a single cell")
    func a1Parsing() {
        #expect(CellRange(a1: "A1:B5")?.a1String == "A1:B5")
        #expect(CellRange(a1: "B5:A1")?.a1String == "A1:B5")
        #expect(CellRange(a1: "C3")?.a1String == "C3")
        #expect(CellRange(a1: "C3:C3")?.a1String == "C3")
        #expect(CellRange(a1: "C3:C3")?.a1String(collapseSingleCell: false) == "C3:C3")
        #expect(CellRange(a1: "A1:") == nil)
        #expect(CellRange(a1: ":B5") == nil)
        #expect(CellRange(a1: "A1:B5:C9") == nil)
        #expect(CellRange(a1: "XFE1:A1") == nil)
    }

    @Test("intersection and union behave like rectangles")
    func setOperations() throws {
        let left = try #require(CellRange(a1: "A1:D4"))
        let right = try #require(CellRange(a1: "C3:F6"))
        #expect(left.intersects(right))
        #expect(left.intersection(right)?.a1String == "C3:D4")
        #expect(left.union(right).a1String == "A1:F6")

        let apart = try #require(CellRange(a1: "Z90:AA95"))
        #expect(!left.intersects(apart))
        #expect(left.intersection(apart) == nil)
        // A union of disjoint rectangles is a bounding box, covering cells in neither.
        #expect(left.union(apart).a1String == "A1:AA95")
    }

    @Test("containment covers both cells and ranges")
    func containment() throws {
        let range = try #require(CellRange(a1: "B2:D5"))
        #expect(range.contains(CellRef(a1: "B2")!))
        #expect(range.contains(CellRef(a1: "D5")!))
        #expect(range.contains(CellRef(a1: "C3")!))
        #expect(!range.contains(CellRef(a1: "A1")!))
        #expect(!range.contains(CellRef(a1: "E5")!))
        #expect(range.contains(try #require(CellRange(a1: "C3:C4"))))
        #expect(!range.contains(try #require(CellRange(a1: "C3:E4"))))
    }

    @Test("iteration is row-major and complete")
    func iteration() throws {
        let range = try #require(CellRange(a1: "B2:D3"))
        let visited = Array(range).map(\.a1String)
        #expect(visited == ["B2", "C2", "D2", "B3", "C3", "D3"])
        #expect(visited.count == range.cellCount)
    }

    @Test("whole-column and whole-row references span the sheet")
    func wholeAxisRanges() {
        let columnA = CellRange.entireColumn(0)
        #expect(columnA.rowCount == Limits.rowCount)
        #expect(columnA.columnCount == 1)
        #expect(columnA.a1String == "A1:A1048576")

        let row1 = CellRange.entireRow(0)
        #expect(row1.columnCount == Limits.columnCount)
        #expect(row1.rowCount == 1)
        #expect(row1.a1String == "A1:XFD1")

        #expect(CellRange.entireSheet.cellCount == Limits.rowCount * Limits.columnCount)
    }

    @Test("clamping and validation agree about the grid")
    func validation() throws {
        let offSheet = CellRange(start: CellRef(row: -3, column: -3), end: CellRef(row: 4, column: 4))
        #expect(!offSheet.isValid)
        #expect(throws: SheetError.self) { try offSheet.validated() }
        #expect(offSheet.clampedToSheet.a1String == "A1:E5")
        #expect(offSheet.intersection(.entireSheet)?.a1String == "A1:E5")

        let entirelyOffSheet = CellRange(start: CellRef(row: -9, column: -9), end: CellRef(row: -5, column: -5))
        #expect(entirelyOffSheet.intersection(.entireSheet) == nil)
    }

    @Test("offsetting moves both corners")
    func offsetting() throws {
        let range = try #require(CellRange(a1: "B2:C3"))
        #expect(range.offset(rows: 2).a1String == "B4:C5")
        #expect(range.offset(columns: 1).a1String == "C2:D3")
        #expect(range.offset(rows: -1, columns: -1).a1String == "A1:B2")
    }
}

@Suite("A1Notation — sheet-qualified references")
struct A1NotationTests {
    @Test("unqualified references parse with no sheet")
    func unqualified() throws {
        let parsed = try #require(A1Notation.parse("A1:D20"))
        #expect(parsed.sheetName == nil)
        #expect(parsed.range.a1String == "A1:D20")
    }

    @Test("a plain sheet name splits on the separator")
    func plainSheetName() throws {
        let parsed = try #require(A1Notation.parse("Sheet1!A1:D20"))
        #expect(parsed.sheetName == "Sheet1")
        #expect(parsed.range.a1String == "A1:D20")
    }

    @Test("a quoted sheet name survives spaces and doubled apostrophes")
    func quotedSheetName() throws {
        let spaced = try #require(A1Notation.parse("'Q4 Data'!B7"))
        #expect(spaced.sheetName == "Q4 Data")
        #expect(spaced.range.a1String == "B7")

        let apostrophe = try #require(A1Notation.parse("'Bob''s Sheet'!A1"))
        #expect(apostrophe.sheetName == "Bob's Sheet")

        #expect(A1Notation.parse("'Unterminated!A1") == nil)
        #expect(A1Notation.parse("'Name'A1") == nil)
    }

    @Test("quoting is applied only where the syntax needs it", arguments: [
        ("Sheet1", "Sheet1"),
        ("Data_2", "Data_2"),
        ("Q4 Data", "'Q4 Data'"),
        ("2024", "'2024'"),
        ("Bob's", "'Bob''s'"),
        ("Ünïcode", "'Ünïcode'"),
        ("📊", "'📊'"),
        ("العربية", "'العربية'"),
        ("a-b", "'a-b'"),
    ])
    func quoting(_ name: String, _ expected: String) {
        #expect(A1Notation.quoteIfNeeded(name) == expected)
    }

    @Test("formatting and parsing are inverses for awkward names", arguments: [
        "Sheet1", "Q4 Data", "Bob's Sheet", "📊 Dashboard", "العربية", "2024",
    ])
    func roundTrip(_ name: String) throws {
        let range = try #require(CellRange(a1: "B2:D5"))
        let text = A1Notation.format(sheetName: name, range: range)
        let parsed = try #require(A1Notation.parse(text))
        #expect(parsed.sheetName == name)
        #expect(parsed.range == range)
    }
}
