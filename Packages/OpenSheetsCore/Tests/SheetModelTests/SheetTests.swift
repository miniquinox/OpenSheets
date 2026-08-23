import Foundation
@testable import SheetModel
import Testing

@Suite("Sheet")
struct SheetTests {
    private func makeSheet() throws -> Sheet {
        var sheet = Sheet(id: SheetID(1), name: "Data")
        for row in 0 ..< 6 {
            for column in 0 ..< 4 {
                try sheet.cells.setCell(.number(Double(row * 10 + column)), at: CellRef(row: row, column: column))
            }
        }
        return sheet
    }

    @Test("usedRange comes from the cells, never from the declared dimension")
    func usedRangeIgnoresDeclaredDimension() throws {
        var sheet = try makeSheet()
        sheet.declaredDimension = CellRange(a1: "A1:ZZ99999")
        #expect(sheet.usedRange?.a1String == "A1:D6")
        #expect(sheet.declaredDimension?.a1String == "A1:ZZ99999", "the claim still round-trips")
    }

    @Test("formattedExtent widens the used range to cover empty formatted columns")
    func formattedExtent() throws {
        var sheet = Sheet(id: SheetID(1), name: "Formats")
        #expect(sheet.usedRange == nil)
        #expect(sheet.formattedExtent == nil)

        sheet.columnStyles.setValue(StyleID(3), in: 0 ... 5)
        let extent = try #require(sheet.formattedExtent)
        #expect(extent.end.column == 5)
        #expect(sheet.usedRange == nil, "formatting alone is not data")
    }

    @Test("style precedence is cell, then row, then column")
    func stylePrecedence() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        sheet.columnStyles.setValue(StyleID(10), in: 2 ... 2)
        sheet.rowStyles.setValue(StyleID(20), in: 4 ... 4)
        try sheet.cells.setCell(Cell(value: .number(1), styleID: StyleID(30)), at: CellRef(row: 4, column: 2))
        try sheet.cells.setCell(.number(2), at: CellRef(row: 5, column: 2))

        #expect(sheet.effectiveStyleID(at: CellRef(row: 4, column: 2)) == StyleID(30), "the cell wins")
        #expect(sheet.effectiveStyleID(at: CellRef(row: 4, column: 9)) == StyleID(20), "then the row")
        #expect(sheet.effectiveStyleID(at: CellRef(row: 5, column: 2)) == StyleID(10), "then the column")
        #expect(sheet.effectiveStyleID(at: CellRef(row: 9, column: 9)) == .default)
    }

    @Test("inserting rows moves cells, sizes, merges, links, and array regions together")
    func insertRowsMovesEverything() throws {
        var sheet = try makeSheet()
        sheet.rowHeights[3] = 60
        sheet.merges = [try #require(CellRange(a1: "A4:B4"))]
        sheet.hyperlinks[try #require(CellRef(a1: "C4"))] = Hyperlink(target: "https://example.com")
        let arrayRegion: CellRange = try #require(CellRange(a1: "A4:B5"))
        let filterRange: CellRange = try #require(CellRange(a1: "A1:D6"))
        sheet.arrayFormulaRanges[try #require(CellRef(a1: "A4"))] = arrayRegion
        sheet.autoFilter = filterRange

        try sheet.insertRows(at: 1, count: 2)

        #expect(sheet.cells[try #require(CellRef(a1: "A6"))]?.value == .number(30), "row 4 moved to row 6")
        #expect(sheet.rowHeights[5] == 60, "the custom height moved with it")
        #expect(sheet.rowHeights[3] == sheet.defaultRowHeight)
        #expect(sheet.merges.first?.a1String == "A6:B6")
        #expect(sheet.hyperlinks[try #require(CellRef(a1: "C6"))] != nil)
        #expect(sheet.hyperlinks[try #require(CellRef(a1: "C4"))] == nil)
        #expect(sheet.arrayFormulaRanges[try #require(CellRef(a1: "A6"))]?.a1String == "A6:B7")
        #expect(sheet.autoFilter?.a1String == "A1:D8")
    }

    @Test("deleting rows removes what falls inside the band")
    func deleteRowsRemovesContainedThings() throws {
        var sheet = try makeSheet()
        sheet.merges = [
            try #require(CellRange(a1: "A2:B2")), // entirely inside the deleted band
            try #require(CellRange(a1: "A5:B6")), // below it, shifts up
        ]
        sheet.hyperlinks[try #require(CellRef(a1: "C2"))] = Hyperlink(target: "https://example.com")
        sheet.rowHeights[1] = 60

        try sheet.deleteRows(at: 1, count: 2)

        #expect(sheet.merges.count == 1)
        #expect(sheet.merges.first?.a1String == "A3:B4")
        #expect(sheet.hyperlinks.isEmpty, "a link inside the deleted band goes with it")
        #expect(sheet.rowHeights[1] == sheet.defaultRowHeight)
        #expect(sheet.cells[try #require(CellRef(a1: "A2"))]?.value == .number(30))
    }

    @Test("inserting and deleting columns moves the column-axis state")
    func columnEdits() throws {
        var sheet = try makeSheet()
        sheet.columnWidths[1] = 200
        sheet.hiddenColumns.setValue(true, in: 2 ... 2)
        sheet.merges = [try #require(CellRange(a1: "B1:C1"))]

        try sheet.insertColumns(at: 1, count: 1)
        #expect(sheet.columnWidths[2] == 200)
        #expect(sheet.hiddenColumns[3])
        #expect(sheet.merges.first?.a1String == "C1:D1")

        try sheet.deleteColumns(at: 1, count: 1)
        #expect(sheet.columnWidths[1] == 200)
        #expect(sheet.hiddenColumns[2])
        #expect(sheet.merges.first?.a1String == "B1:C1")
    }

    @Test("validation catches overlapping merges and bad names")
    func validation() throws {
        var sheet = try makeSheet()
        try sheet.validate()

        sheet.merges = [
            try #require(CellRange(a1: "A1:C3")),
            try #require(CellRange(a1: "B2:D4")),
        ]
        #expect(throws: SheetError.self) { try sheet.validate() }

        sheet.merges = [
            try #require(CellRange(a1: "A1:B2")),
            try #require(CellRange(a1: "C1:D2")),
        ]
        try sheet.validate()

        sheet.name = "Has/Slash"
        #expect(throws: SheetError.self) { try sheet.validate() }
        sheet.name = String(repeating: "x", count: 32)
        #expect(throws: SheetError.self) { try sheet.validate() }
        sheet.name = ""
        #expect(throws: SheetError.self) { try sheet.validate() }
    }

    @Test("sheet names Excel forbids are refused", arguments: [
        "", "Has[Bracket]", "Has:Colon", "Has*Star", "Has?Question", "Has/Slash", "Has\\Backslash",
        "'Leading", "Trailing'", "History",
    ])
    func forbiddenNames(_ name: String) {
        #expect(throws: SheetError.self) { try Limits.validateSheetName(name) }
    }

    @Test("sheet names that are merely unusual are accepted", arguments: [
        "Sheet1", "Q4 Data", "📊 Dashboard", "العربية", "日本語", "a.b-c", "Bob's Sheet",
        String(repeating: "x", count: 31),
    ])
    func acceptableNames(_ name: String) throws {
        try Limits.validateSheetName(name)
    }

    @Test("frozen panes report how many quadrants must be drawn")
    func paneQuadrants() {
        #expect(FrozenPanes.none.paneCount == 1)
        #expect(!FrozenPanes.none.isFrozen)
        #expect(FrozenPanes(frozenRows: 1).paneCount == 2)
        #expect(FrozenPanes(frozenColumns: 1).paneCount == 2)
        #expect(FrozenPanes(frozenRows: 1, frozenColumns: 1).paneCount == 4)
        #expect(FrozenPanes(frozenRows: 1).isFrozen)
        #expect(FrozenPanes(horizontalSplit: 100).isSplit)
        #expect(!FrozenPanes(horizontalSplit: 100).isFrozen)
    }

    @Test("merge lookup finds the containing region")
    func mergeLookup() throws {
        var sheet = try makeSheet()
        sheet.merges = [try #require(CellRange(a1: "B2:C3"))]
        #expect(sheet.merge(containing: try #require(CellRef(a1: "B2")))?.a1String == "B2:C3")
        #expect(sheet.merge(containing: try #require(CellRef(a1: "C3")))?.a1String == "B2:C3")
        #expect(sheet.merge(containing: try #require(CellRef(a1: "D3"))) == nil)
    }
}

@Suite("Workbook")
struct WorkbookTests {
    private func makeWorkbook() -> Workbook {
        Workbook(sheets: [
            Sheet(id: SheetID(1), name: "Data"),
            Sheet(id: SheetID(2), name: "Summary"),
        ])
    }

    @Test("blank workbooks start with one sheet")
    func blank() {
        let workbook = Workbook.blank()
        #expect(workbook.sheets.count == 1)
        #expect(workbook.sheets[0].name == "Sheet1")
        #expect(workbook.cellCount == 0)
    }

    @Test("sheet lookup by id and by name, the latter case-insensitively")
    func lookup() throws {
        let workbook = makeWorkbook()
        #expect(workbook[SheetID(1)]?.name == "Data")
        #expect(workbook.sheet(named: "Data")?.id == SheetID(1))
        #expect(workbook.sheet(named: "data")?.id == SheetID(1), "Excel compares without case")
        #expect(workbook.sheet(named: "DATA")?.id == SheetID(1))
        #expect(workbook.sheet(named: "Missing") == nil)
        #expect(workbook.index(of: SheetID(2)) == 1)
        #expect(try workbook.requireSheet(named: "Summary").id == SheetID(2))
        #expect(throws: SheetError.self) { try workbook.requireSheet(named: "Missing") }
        #expect(throws: SheetError.self) { try workbook.requireSheet(id: SheetID(99)) }
    }

    @Test("adding a sheet checks the name is legal and unique")
    func addingSheets() throws {
        var workbook = makeWorkbook()
        try workbook.addSheet(Sheet(id: workbook.nextSheetID, name: "Q4"))
        #expect(workbook.sheets.count == 3)
        #expect(workbook.sheets.last?.name == "Q4")
        #expect(workbook.nextSheetID == SheetID(4))

        #expect(throws: SheetError.self) { try workbook.addSheet(Sheet(id: SheetID(9), name: "data")) }
        #expect(throws: SheetError.self) { try workbook.addSheet(Sheet(id: SheetID(9), name: "Bad/Name")) }

        try workbook.addSheet(Sheet(id: SheetID(9), name: "First"), at: 0)
        #expect(workbook.sheets.first?.name == "First")
    }

    @Test("renaming checks uniqueness but lets a sheet keep its own name")
    func renaming() throws {
        var workbook = makeWorkbook()
        try workbook.renameSheet(SheetID(1), to: "Numbers")
        #expect(workbook[SheetID(1)]?.name == "Numbers")

        try workbook.renameSheet(SheetID(1), to: "Numbers")
        #expect(throws: SheetError.self) { try workbook.renameSheet(SheetID(1), to: "Summary") }
        #expect(throws: SheetError.self) { try workbook.renameSheet(SheetID(1), to: "summary") }
        #expect(throws: SheetError.self) { try workbook.renameSheet(SheetID(99), to: "Whatever") }
    }

    @Test("the last sheet cannot be removed")
    func removingSheets() throws {
        var workbook = makeWorkbook()
        let removed = try workbook.removeSheet(SheetID(1))
        #expect(removed.name == "Data")
        #expect(workbook.sheets.count == 1)
        #expect(throws: SheetError.self) { try workbook.removeSheet(SheetID(2)) }
        #expect(throws: SheetError.self) { try workbook.removeSheet(SheetID(99)) }
    }

    @Test("withSheet mutates in place")
    func mutatingASheet() throws {
        var workbook = makeWorkbook()
        try workbook.withSheet(SheetID(1)) { sheet in
            try sheet.cells.setCell(.number(42), at: .origin)
        }
        #expect(workbook[SheetID(1)]?.cells[.origin]?.value == .number(42))
        #expect(workbook.cellCount == 1)
        #expect(throws: SheetError.self) {
            try workbook.withSheet(SheetID(99)) { _ in }
        }
    }

    @Test("defined names resolve sheet scope before workbook scope")
    func definedNameScoping() throws {
        var workbook = makeWorkbook()
        try workbook.setDefinedName(DefinedName(
            name: "Total", target: RangeReference(range: CellRange(a1: "A1:A10")!), formula: "Data!$A$1:$A$10"
        ))
        try workbook.setDefinedName(DefinedName(
            name: "Total", scope: SheetID(2),
            target: RangeReference(sheet: SheetID(2), range: CellRange(a1: "B1:B5")!),
            formula: "Summary!$B$1:$B$5"
        ))

        #expect(workbook.definedNames.count == 2, "the two scopes coexist")
        #expect(workbook.definedName("Total")?.target?.range.a1String == "A1:A10")
        #expect(workbook.definedName("Total", scope: SheetID(2))?.target?.range.a1String == "B1:B5")
        #expect(
            workbook.definedName("Total", scope: SheetID(1))?.target?.range.a1String == "A1:A10",
            "a sheet with no local name falls back to the workbook one"
        )
        #expect(workbook.definedName("TOTAL")?.formula == "Data!$A$1:$A$10", "names fold case")
        #expect(workbook.definedName("Missing") == nil)
    }

    @Test("defined names visible from a sheet include the global ones")
    func visibleNames() throws {
        var workbook = makeWorkbook()
        try workbook.setDefinedName(DefinedName(name: "Global", formula: "Data!$A$1"))
        try workbook.setDefinedName(DefinedName(name: "Local", scope: SheetID(1), formula: "Data!$B$1"))
        try workbook.setDefinedName(DefinedName(name: "Other", scope: SheetID(2), formula: "Summary!$C$1"))

        #expect(workbook.definedNames(visibleFrom: SheetID(1)).map(\.name) == ["Global", "Local"])
        #expect(workbook.definedNames(visibleFrom: SheetID(2)).map(\.name) == ["Global", "Other"])
        #expect(workbook.definedNames(visibleFrom: nil).map(\.name) == ["Global"])
    }

    @Test("a defined name whose target is not a plain range still round-trips")
    func nonRangeDefinedNames() throws {
        var workbook = makeWorkbook()
        let computed = DefinedName(name: "Doubled", target: nil, formula: "SUM(Data!A:A)*2")
        try workbook.setDefinedName(computed)
        #expect(workbook.definedName("Doubled")?.target == nil)
        #expect(workbook.definedName("Doubled")?.formula == "SUM(Data!A:A)*2")
    }

    @Test("defined-name identifiers follow Excel's rules", arguments: [
        "1Total", "A1", "XFD1048576", "R", "C", "r", "has space", "has-dash", "", "Total!",
    ])
    func rejectsBadDefinedNames(_ name: String) {
        #expect(throws: SheetError.self) { try DefinedName.validate(name: name) }
    }

    @Test("defined-name identifiers that are fine", arguments: [
        "Total", "_private", "Total.2024", "\\weird", "Rate", "Column", "データ",
    ])
    func acceptsGoodDefinedNames(_ name: String) throws {
        try DefinedName.validate(name: name)
    }

    @Test("removing a defined name honours scope")
    func removingDefinedNames() throws {
        var workbook = makeWorkbook()
        try workbook.setDefinedName(DefinedName(name: "Total", formula: "A1"))
        try workbook.setDefinedName(DefinedName(name: "Total", scope: SheetID(1), formula: "B1"))
        #expect(workbook.removeDefinedName("Total", scope: SheetID(1))?.formula == "B1")
        #expect(workbook.definedName("Total", scope: SheetID(1))?.formula == "A1")
        #expect(workbook.removeDefinedName("Total")?.formula == "A1")
        #expect(workbook.definedNames.isEmpty)
    }

    @Test("workbook validation catches colliding names and unknown styles")
    func validation() throws {
        var workbook = makeWorkbook()
        try workbook.validate()

        workbook.sheets[1].name = "data"
        #expect(throws: SheetError.self) { try workbook.validate() }
        workbook.sheets[1].name = "Summary"

        try workbook.withSheet(SheetID(1)) { sheet in
            try sheet.cells.setCell(Cell(value: .number(1), styleID: StyleID(99)), at: .origin)
        }
        #expect(throws: SheetError.self) { try workbook.validate() }

        var empty = Workbook()
        #expect(throws: SheetError.self) { try empty.validate() }
        empty.sheets = [Sheet(id: SheetID(1), name: "S")]
        try empty.validate()
    }

    @Test("read-only workbooks report that saving is refused")
    func readOnlyReporting() {
        var meta = WorkbookMeta()
        #expect(meta.isWritable)
        meta.readOnlyReason = .encrypted
        #expect(!meta.isWritable)

        let error = SheetError.writeRefused(reason: .encrypted)
        #expect(error.message.contains("password-protected"))
        #expect(error.code == "file.writeRefused")

        for reason in ReadOnlyReason.allCases {
            #expect(!reason.message.isEmpty)
            #expect(SheetError.writeRefused(reason: reason).message.count > 20)
        }
    }
}
