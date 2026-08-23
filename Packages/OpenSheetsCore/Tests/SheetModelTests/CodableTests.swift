import Foundation
@testable import SheetModel
import Testing

/// Everything in `SheetModel` is `Codable` because two consumers need it: A7's fixture
/// sidecars (`Fixtures/**/*.expected.json`) and A9's MCP wire format. A conformance that
/// silently loses a field would make both of them quietly wrong, so this round-trips values
/// rather than trusting the synthesised code.
@Suite("Codable round-trips")
struct CodableTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try JSONDecoder().decode(T.self, from: encoder.encode(value))
    }

    @Test("cell values encode with the same type letters xlsx uses")
    func cellValueTagging() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(String(decoding: try encoder.encode(CellValue.empty), as: UTF8.self) == #"{"t":"z"}"#)
        #expect(String(decoding: try encoder.encode(CellValue.number(42)), as: UTF8.self) == #"{"t":"n","v":42}"#)
        #expect(String(decoding: try encoder.encode(CellValue.text("hi")), as: UTF8.self) == #"{"t":"s","v":"hi"}"#)
        #expect(String(decoding: try encoder.encode(CellValue.boolean(true)), as: UTF8.self) == #"{"t":"b","v":true}"#)
        let encodedError = String(decoding: try encoder.encode(CellValue.error(.divideByZero)), as: UTF8.self)
        #expect(encodedError.contains(##""t":"e""##))
        #expect(encodedError.contains("DIV"))
        #expect(try roundTrip(CellValue.error(.divideByZero)) == .error(.divideByZero))
    }

    @Test("every cell value round-trips", arguments: [
        CellValue.empty, .number(42), .number(-0.5), .number(1e300), .text(""), .text("hello"),
        .text("emoji 📊 and \"quotes\""), .boolean(true), .boolean(false),
        .error(.divideByZero), .error(.notAvailable), .error(.circular),
    ])
    func cellValues(_ value: CellValue) throws {
        #expect(try roundTrip(value) == value)
    }

    @Test("an unknown value tag is rejected rather than guessed")
    func rejectsUnknownTags() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CellValue.self, from: Data(#"{"t":"q","v":1}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(CellValue.self, from: Data(##"{"t":"e","v":"#NOPE!"}"##.utf8))
        }
    }

    @Test("cells keep their formula, style, and flags")
    func cells() throws {
        let cell = Cell(
            value: .number(129.6),
            formula: "B2*1.08",
            styleID: StyleID(7),
            flags: [.staleCache, .externalLink]
        )
        let decoded = try roundTrip(cell)
        #expect(decoded == cell)
        #expect(decoded.flags.contains(.staleCache))
        #expect(decoded.flags.contains(.externalLink))
        #expect(!decoded.flags.contains(.arrayFormula))
    }

    @Test("references and ranges round-trip")
    func referencesAndRanges() throws {
        #expect(try roundTrip(CellRef(row: 1_048_575, column: 16_383)).a1String == "XFD1048576")
        #expect(try roundTrip(CellRange(a1: "B2:D5")!).a1String == "B2:D5")
    }

    @Test("a cell store survives a round-trip with its sparsity intact")
    func cellStores() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try store.setCell(.text("x"), at: CellRef(row: 0, column: 5))
        try store.setCell(.formula("A1*2", cached: .number(2)), at: CellRef(row: 999, column: 3))
        try store.setCell(.styled(StyleID(4)), at: CellRef(row: 1_048_575, column: 16_383))

        let decoded = try roundTrip(store)
        #expect(decoded == store)
        #expect(decoded.count == 4)
        #expect(decoded.usedRange?.a1String == "A1:XFD1048576")
        #expect(decoded[CellRef(row: 999, column: 3)]?.formula == "A1*2")
    }

    @Test("a store decodes as rows of parallel columns and values")
    func cellStoreShape() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try store.setCell(.number(2), at: CellRef(row: 0, column: 2))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(store), as: UTF8.self)
        #expect(json.contains(#""r":0"#))
        #expect(json.contains(#""c":[0,2]"#))
    }

    @Test("a store with mismatched columns and values is rejected")
    func cellStoreValidatesShape() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CellStore.self,
                from: Data(#"[{"r":0,"c":[0,1],"v":[{"t":"n","v":1}]}]"#.utf8)
            )
        }
    }

    @Test("run-length arrays keep their runs, not an expansion")
    func runLengthArrays() throws {
        var widths = RunLengthArray(defaultValue: 64.0)
        widths.setValue(120, in: 0 ... 2)
        widths.setValue(200, in: 16_380 ... 16_383)

        let decoded = try roundTrip(widths)
        #expect(decoded == widths)
        #expect(decoded.runCount == 2, "decoding must not expand to one entry per column")
        #expect(decoded[1] == 120)
        #expect(decoded[16_383] == 200)
        #expect(decoded[500] == 64)
    }

    @Test("a run whose bounds are inverted is rejected")
    func runLengthValidation() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                RunLengthArray<Double>.self,
                from: Data(#"{"defaultValue":1,"runs":[{"lower":9,"upper":2,"value":5}]}"#.utf8)
            )
        }
    }

    @Test("number formats round-trip with their parsed sections")
    func numberFormats() throws {
        for code in ["General", "0.00", "#,##0", "0%", "$#,##0.00;[Red]($#,##0.00)", "yyyy-mm-dd", "@", "[h]:mm:ss"] {
            let decoded = try roundTrip(NumberFormat(code))
            #expect(decoded.formatCode == code)
            #expect(decoded.kind == NumberFormat(code).kind)
            #expect(decoded.sections.count == NumberFormat(code).sections.count)
        }
    }

    @Test("style tables keep both their styles and their custom formats")
    func styleTables() throws {
        var table = StyleTable.empty
        let id = table.derive(.default) {
            $0.font.isBold = true
            $0.fill = .solid(.theme(index: 4, tint: -0.25))
            $0.alignment.horizontal = .center
            $0.quotePrefix = true
        }
        table.customNumberFormatsForTesting(id: 200, format: NumberFormat("yyyy\"年\""))

        let decoded = try roundTrip(table)
        #expect(decoded[id].font.isBold)
        #expect(decoded[id].fill.effectiveColor == .theme(index: 4, tint: -0.25))
        #expect(decoded[id].alignment.horizontal == .center)
        #expect(decoded[id].quotePrefix)
        #expect(decoded.numberFormat(id: 200).formatCode == "yyyy\"年\"")
    }

    @Test("a sheet round-trips including its ref-keyed dictionaries")
    func sheets() throws {
        var sheet = Sheet(id: SheetID(3), name: "Q4 📊", partPath: "xl/worksheets/sheet3.xml")
        try sheet.cells.setCell(.number(42), at: .origin)
        sheet.columnWidths[2] = 180
        sheet.hiddenRows.setValue(true, in: 5 ... 7)
        sheet.merges = [CellRange(a1: "B2:C3")!]
        sheet.frozen = FrozenPanes(frozenRows: 1, frozenColumns: 2)
        sheet.hyperlinks[CellRef(a1: "D4")!] = Hyperlink(target: "https://example.com", tooltip: "Docs")
        sheet.arrayFormulaRanges[CellRef(a1: "A1")!] = CellRange(a1: "A1:B2")!
        sheet.tabColor = .rgb(.red)
        sheet.visibility = .veryHidden
        sheet.autoFilter = CellRange(a1: "A1:D10")!

        let decoded = try roundTrip(sheet)
        #expect(decoded.name == "Q4 📊")
        #expect(decoded.partPath == "xl/worksheets/sheet3.xml")
        #expect(decoded.cells[.origin]?.value == .number(42))
        #expect(decoded.columnWidths[2] == 180)
        #expect(decoded.hiddenRows[6])
        #expect(decoded.merges.first?.a1String == "B2:C3")
        #expect(decoded.frozen.paneCount == 4)
        #expect(decoded.hyperlinks[CellRef(a1: "D4")!]?.tooltip == "Docs")
        #expect(decoded.arrayFormulaRanges[CellRef(a1: "A1")!]?.a1String == "A1:B2")
        #expect(decoded.tabColor == .rgb(.red))
        #expect(decoded.visibility == .veryHidden)
        #expect(decoded.autoFilter?.a1String == "A1:D10")
        #expect(decoded == sheet)
    }

    @Test("a whole workbook round-trips, passthrough entries included")
    func workbooks() throws {
        var workbook = Workbook.blank(sheetName: "Data")
        try workbook.withSheet(SheetID(1)) { sheet in
            try sheet.cells.setCell(.formula("SUM(A1:A9)", cached: .number(42)), at: CellRef(a1: "B1")!)
        }
        try workbook.setDefinedName(DefinedName(
            name: "Total", target: RangeReference(range: CellRange(a1: "A1:A9")!), formula: "Data!$A$1:$A$9"
        ))
        workbook.meta.dateSystem = .excel1904
        workbook.meta.sourceFormat = .xlsm
        workbook.meta.containsMacros = true
        workbook.meta.readOnlyReason = .unknownCriticalPart
        workbook.passthrough = OpaqueParts(
            entries: [ZipEntry(path: "xl/vbaProject.bin", compressedData: Data([0xCA, 0xFE]), crc32: 7)],
            modelled: ["xl/workbook.xml"]
        )

        let decoded = try roundTrip(workbook)
        #expect(decoded.sheets.count == 1)
        #expect(decoded[SheetID(1)]?.cells[CellRef(a1: "B1")!]?.formula == "SUM(A1:A9)")
        #expect(decoded.definedName("Total")?.formula == "Data!$A$1:$A$9")
        #expect(decoded.meta.dateSystem == .excel1904)
        #expect(decoded.meta.containsMacros)
        #expect(decoded.meta.readOnlyReason == .unknownCriticalPart)
        #expect(!decoded.meta.isWritable)
        #expect(decoded.passthrough["xl/vbaProject.bin"]?.compressedData == Data([0xCA, 0xFE]))
        #expect(decoded.passthrough.modelled == ["xl/workbook.xml"])
        #expect(decoded == workbook)
    }

    @Test("CSV dialects round-trip, including their single-character fields")
    func csvDialects() throws {
        let dialect = CSVDialect(
            delimiter: ";", quote: "'", lineEnding: .crlf, hasByteOrderMark: true,
            encodingName: "windows-1252", encodingWasGuessed: true, hasHeaderRow: true,
            endsWithoutNewline: true
        )
        let decoded = try roundTrip(dialect)
        #expect(decoded == dialect)
        #expect(decoded.delimiter == ";")
        #expect(decoded.lineEnding.characters == "\r\n")
    }

    @Test("diffs round-trip so an MCP write can report what it did")
    func diffs() throws {
        let diff = WorkbookDiff(
            sheetDiffs: [SheetDiff(
                sheetID: SheetID(1), sheetName: "Data",
                cellChanges: [CellChange(
                    ref: CellRef(a1: "D2")!, before: .number(120), after: .number(129.6), kind: .valueChanged
                )],
                structuralChanges: [StructuralChange(kind: .insertedRows, index: 4, count: 1)],
                omittedCellChangeCount: 3, addedCount: 1, removedCount: 0, changedCount: 4
            )],
            addedSheets: [SheetSummary(id: SheetID(2), name: "Q4", cellCount: 320)],
            renamedSheets: [SheetRename(id: SheetID(1), before: "Sheet1", after: "Data")]
        )
        #expect(try roundTrip(diff) == diff)
    }
}

extension StyleTable {
    /// Interning goes through ``internNumberFormat(_:)`` in real code, which allocates the next
    /// free id. The Codable test needs a specific id, so it seeds one directly.
    mutating func customNumberFormatsForTesting(id: Int32, format: NumberFormat) {
        var seeded = customNumberFormats
        seeded[id] = format
        self = StyleTable(styles: styles, customNumberFormats: seeded, palette: palette)
    }
}
