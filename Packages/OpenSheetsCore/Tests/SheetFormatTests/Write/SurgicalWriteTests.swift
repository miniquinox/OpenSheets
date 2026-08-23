//
//  SurgicalWriteTests.swift
//  SheetFormatTests
//
//  Per-part dirty tracking, calcChain, `_xlfn.`, escaping, and the refusals.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel
import Testing

@Suite("Surgical write")
struct SurgicalWriteTests {
    // MARK: - Dirty tracking is per part

    @Test("editing one sheet does not rewrite the others")
    func editingOneSheetLeavesTheRestAlone() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let third = try #require(workbook.sheets.first { $0.name == "Three" })

        try workbook.withSheet(third.id) { sheet in
            try sheet.cells.setCell(Cell.number(99), at: CellRef(row: 5, column: 5))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[third.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))

        for path in [
            HandBuiltPackage.sheet1Path, HandBuiltPackage.sheet2Path, OOXMLPart.styles,
            OOXMLPart.workbook, OOXMLPart.contentTypes, OOXMLPart.calcChain,
        ] {
            let before = try #require(loaded.archive[path])
            let after = try #require(rewritten[path], "\(path) disappeared")
            #expect(after.compressedData == before.compressedData, "\(path) was rewritten but nothing changed in it")
        }
        #expect(try rewritten.text(HandBuiltPackage.sheet3Path).contains("r=\"F6\""))
    }

    @Test("a sheet that was never marked dirty is not rewritten even when its model changed")
    func onlyMarkedSheetsAreWritten() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let second = try #require(workbook.sheets.first { $0.name == "Two" })
        try workbook.withSheet(second.id) { sheet in
            try sheet.cells.setCell(Cell.number(1234), at: CellRef(row: 0, column: 0))
        }

        // Deliberately not told about it: the writer must not go looking.
        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: WorkbookEditTracker()))
        let before = try #require(loaded.archive[HandBuiltPackage.sheet2Path])
        #expect(try #require(rewritten[HandBuiltPackage.sheet2Path]).compressedData == before.compressedData)
    }

    // MARK: - calcChain

    @Test("a formula change drops calcChain and asks Excel to recalculate")
    func formulaChangeDropsTheCalculationChain() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)

        try workbook.withSheet(first.id) { sheet in
            try sheet.cells.setCell(
                Cell.formula("SUM(A2:B2)", cached: .number(3)), at: CellRef(row: 1, column: 2)
            )
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[first.id]), formulasChanged: true)

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))

        #expect(rewritten[OOXMLPart.calcChain] == nil, "calcChain.xml survived a formula change")
        #expect(!(try rewritten.text(OOXMLPart.contentTypes)).contains("calcChain"),
                "the content-type override for calcChain is still there, pointing at nothing")
        #expect(!(try rewritten.text(OOXMLPart.workbookRelationships)).contains("calcChain.xml"),
                "the relationship to calcChain is still there, pointing at nothing")
        #expect(try rewritten.text(OOXMLPart.workbook).contains("fullCalcOnLoad=\"1\""))
        // The existing calcPr attributes survive the patch.
        #expect(try rewritten.text(OOXMLPart.workbook).contains("calcId=\"171027\""))
    }

    @Test("a value-only change keeps calcChain")
    func valueChangeKeepsTheCalculationChain() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)
        try workbook.withSheet(first.id) { sheet in
            try sheet.cells.setCell(Cell.number(42), at: CellRef(row: 1, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[first.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        #expect(rewritten[OOXMLPart.calcChain] != nil)
        #expect(!(try rewritten.text(OOXMLPart.workbook)).contains("fullCalcOnLoad"))
    }

    // MARK: - Sheet-level splicing

    @Test("legacyDrawing is emitted between drawing and tableParts")
    func legacyDrawingKeepsItsSchemaPosition() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)
        try workbook.withSheet(first.id) { sheet in
            try sheet.cells.setCell(Cell.number(42), at: CellRef(row: 1, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[first.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let scanned = try WorksheetPartScanner.scan(
            try rewritten.text(HandBuiltPackage.sheet1Path), part: HandBuiltPackage.sheet1Path
        )
        let names = scanned.children.map(\.localName)
        let drawing = try #require(names.firstIndex(of: "drawing"))
        let legacy = try #require(names.firstIndex(of: "legacyDrawing"))
        let tables = try #require(names.firstIndex(of: "tableParts"))
        let extensions = try #require(names.firstIndex(of: "extLst"))
        #expect(drawing < legacy)
        #expect(legacy < tables)
        #expect(tables < extensions)
    }

    @Test("the model carries legacyDrawing, so the writer needs no local correction")
    func theModelOrdersLegacyDrawingCorrectly() {
        // This began life as a tripwire asserting the model was WRONG, with a local correction in
        // WorksheetChildOrder compensating. The model was fixed mid-wave; the tripwire fired as
        // designed and the correction was retired. What it guards now is the fix itself — a
        // regression here means <legacyDrawing> sorts past <tableParts> again, Excel drops it,
        // and every comment in the workbook is orphaned behind a comments1.xml nothing points at.
        #expect(SheetFragment.worksheetChildOrder.contains("legacyDrawing"))
        #expect(SheetFragment.worksheetChildOrder.contains("legacyDrawingHF"))
        #expect(SheetFragment.schemaOrder(for: "legacyDrawing") < SheetFragment.schemaOrder(for: "tableParts"))
        #expect(SheetFragment.schemaOrder(for: "drawing") < SheetFragment.schemaOrder(for: "legacyDrawing"))
        // The writer's projection agrees with the model, because it is derived from it.
        #expect(WorksheetChildOrder.canonical == SheetFragment.worksheetChildOrder)
    }

    @Test("fragments are spliced back when there is no original part to salvage from")
    func fragmentsAreSplicedWhenTheOriginalIsGone() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.number(1), at: .origin)
        sheet.sheetLevelFragments = [
            SheetFragment(elementName: "pageMargins", xml: "<pageMargins left=\"1\"/>"),
            SheetFragment(elementName: "sheetPr", xml: "<sheetPr codeName=\"S\"/>"),
            SheetFragment(elementName: "drawing", xml: "<drawing r:id=\"rId1\"/>"),
        ]
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        let scanned = try WorksheetPartScanner.scan(output.xml, part: "S")
        let names = scanned.children.map(\.localName)
        #expect(names.contains("sheetPr"))
        #expect(names.contains("pageMargins"))
        #expect(names.contains("drawing"))
        #expect(try #require(names.firstIndex(of: "sheetPr")) < #require(names.firstIndex(of: "sheetData")))
        #expect(try #require(names.firstIndex(of: "pageMargins")) < #require(names.firstIndex(of: "drawing")))
    }

    // MARK: - Shared strings

    @Test("shared string indexes are stable and rich text survives by index reuse")
    func sharedStringsAreAppendOnly() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)

        // A3 currently holds shared string 3 ("  padded  "); the rich-text entry at index 2 is
        // not referenced by any cell in the fixture, so put it in one.
        try workbook.withSheet(first.id) { sheet in
            try sheet.cells.setCell(
                Cell(value: .text("HelloWorld"), flags: .richText), at: CellRef(row: 3, column: 0)
            )
            try sheet.cells.setCell(Cell.text("brand new string"), at: CellRef(row: 4, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[first.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let sst = try WorksheetPartScanner.scan(
            try rewritten.text(OOXMLPart.sharedStrings), part: OOXMLPart.sharedStrings
        )
        let items = sst.children.filter { $0.localName == "si" }

        #expect(items.count == 5, "the table should have grown by exactly one entry")
        // The originals are byte-identical, including the bold run.
        let original = try WorksheetPartScanner.scan(
            try loaded.archive.text(OOXMLPart.sharedStrings), part: OOXMLPart.sharedStrings
        ).children.filter { $0.localName == "si" }
        for index in original.indices {
            #expect(items[index].text == original[index].text, "si[\(index)] was rewritten")
        }
        #expect(items[2].text.contains("<b/>"), "the bold run was lost")
        #expect(try rewritten.text(OOXMLPart.sharedStrings).contains("uniqueCount=\"5\""))

        // A4 points back at the rich-text entry rather than at a new plain copy.
        let sheetXML = try rewritten.text(HandBuiltPackage.sheet1Path)
        #expect(sheetXML.contains("<c r=\"A4\" t=\"s\"><v>2</v></c>"))
        #expect(sheetXML.contains("<c r=\"A5\" t=\"s\"><v>4</v></c>"))
    }

    @Test("with no shared string part, text is written inline rather than adding one")
    func absentSharedStringsMeansInlineText() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.text("hello"), at: .origin)
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(output.xml.contains("t=\"inlineStr\""))
        #expect(output.xml.contains("<t xml:space=\"preserve\">hello</t>"))
    }

    // MARK: - Formulas

    @Test("_xlfn. is re-emitted so Excel does not show #NAME?")
    func newerFunctionsKeepTheirStoredNames() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.formula("XLOOKUP(A1,B:B,C:C)", cached: .number(1)), at: .origin)
        try sheet.cells.setCell(
            Cell.formula("_xlfn.TEXTJOIN(\",\",1,A1:A2)", cached: .text("x")), at: CellRef(row: 1, column: 0)
        )
        try sheet.cells.setCell(
            Cell.formula("CONCAT(\"XLOOKUP(\",A1)", cached: .text("y")), at: CellRef(row: 2, column: 0)
        )
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(output.xml.contains("<f>_xlfn.XLOOKUP(A1,B:B,C:C)</f>"))
        #expect(output.xml.contains("<f>_xlfn.TEXTJOIN(&quot;,&quot;,1,A1:A2)</f>")
            || output.xml.contains("<f>_xlfn.TEXTJOIN(\",\",1,A1:A2)</f>"))
        // Inside a string literal it stays a string literal.
        #expect(output.xml.contains("_xlfn.CONCAT(\"XLOOKUP(\",A1)"))
    }

    @Test("prefixing leaves ordinary and user-defined names alone", arguments: [
        ("SUM(A1:A2)", "SUM(A1:A2)"),
        ("MYIFS(A1)", "MYIFS(A1)"),
        ("IFS(A1>1,\"a\",TRUE,\"b\")", "_xlfn.IFS(A1>1,\"a\",TRUE,\"b\")"),
        ("'XLOOKUP'!A1", "'XLOOKUP'!A1"),
        ("STDEV.P(A1:A9)", "_xlfn.STDEV.P(A1:A9)"),
        ("A1&\"IFS(\"", "A1&\"IFS(\""),
    ])
    func storedFormRules(_ input: String, _ expected: String) {
        #expect(XLSXFunctionNames.storedForm(input) == expected)
    }

    @Test("an empty formula string is written as no formula, not as <f></f>")
    func emptyFormulasAreNotWritten() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(
            Cell(value: .number(6), formula: "", flags: .sharedFormulaExpansion), at: .origin
        )
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(!output.xml.contains("<f>"))
        #expect(output.xml.contains("<c r=\"A1\"><v>6</v></c>"))
    }

    @Test("an array formula keeps its ref and its followers stay bare")
    func arrayFormulasRoundTrip() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        let anchor = CellRef(row: 0, column: 3)
        try sheet.cells.setCell(
            Cell(value: .number(1), formula: "A1:A3*2", flags: .arrayFormula), at: anchor
        )
        try sheet.cells.setCell(
            Cell(value: .number(2), flags: .arrayFormula), at: CellRef(row: 1, column: 3)
        )
        sheet.arrayFormulaRanges[anchor] = CellRange(a1: "D1:D2")!

        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(output.xml.contains("<f t=\"array\" ref=\"D1:D2\">A1:A3*2</f>"))
        #expect(output.xml.contains("<c r=\"D2\"><v>2</v></c>"))
    }

    // MARK: - Escaping

    @Test("markup characters are escaped")
    func markupIsEscaped() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.text("a < b & c > d \"q\""), at: .origin)
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(output.xml.contains("a &lt; b &amp; c &gt; d \"q\""))
    }

    @Test("characters XML 1.0 cannot represent are escaped, stripped, or refused")
    func illegalControlCharacters() throws {
        let hostile = "before\u{0000}\u{0007}\u{000B}after"

        var escaped = XLSXWriteOptions()
        escaped.controlCharacters = .escape
        #expect(try XLSXEscape.sanitiseCellText(hostile, policy: .escape, ref: "A1")
            == "before_x0000__x0007__x000B_after")

        #expect(try XLSXEscape.sanitiseCellText(hostile, policy: .strip, ref: "A1") == "beforeafter")

        #expect(throws: SheetError.self) {
            try XLSXEscape.sanitiseCellText(hostile, policy: .reject, ref: "A1")
        }

        // Text that already looks like an escape is disambiguated, so decoding is reversible.
        #expect(try XLSXEscape.sanitiseCellText("file_x0041_name\u{0000}", policy: .escape, ref: "A1")
            == "file_x005F_x0041_name_x0000_")
        // Ordinary text is untouched.
        #expect(try XLSXEscape.sanitiseCellText("plain_text", policy: .escape, ref: "A1") == "plain_text")
    }

    @Test("a cell past Excel's text ceiling is refused rather than truncated")
    func overlongTextIsRefused() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(
            Cell.text(String(repeating: "x", count: Limits.maxCellTextLength + 1)), at: .origin
        )
        #expect(throws: SheetError.self) {
            try WorksheetPartWriter.serialise(
                sheet,
                context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
            )
        }
    }

    @Test("numbers round-trip exactly and non-finite values become an error cell")
    func numberFormatting() throws {
        #expect(XLSXEscape.number(42) == "42")
        #expect(XLSXEscape.number(10.5) == "10.5")
        #expect(XLSXEscape.number(-0.000001) == "-1e-06")
        #expect(Double(XLSXEscape.number(.greatestFiniteMagnitude)) == .greatestFiniteMagnitude)
        #expect(Double(XLSXEscape.number(0.1 + 0.2)) == 0.1 + 0.2)

        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.number(.infinity), at: .origin)
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(output.xml.contains("t=\"e\""))
        #expect(output.xml.contains("#NUM!"))
    }

    @Test("#CIRCULAR is never written, because Excel would refuse to open the file")
    func circularIsNotAnXLSXToken() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.error(.circular), at: .origin)
        let output = try WorksheetPartWriter.serialise(
            sheet,
            context: WorksheetPartWriter.Context(originalXML: nil, strings: .absent, regions: .all)
        )
        #expect(!output.xml.contains("#CIRCULAR"))
        #expect(output.xml.contains("#VALUE!"))
    }

    // MARK: - Refusals

    @Test("a read-only workbook is refused", arguments: ReadOnlyReason.allCases)
    func readOnlyWorkbooksAreRefused(_ reason: ReadOnlyReason) throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        workbook.meta.readOnlyReason = reason
        #expect(throws: SheetError.writeRefused(reason: reason)) {
            try XLSXWriter.data(for: workbook, edits: WorkbookEditTracker())
        }
    }

    @Test("changing the set of parts is refused rather than half-done")
    func partStructureChangesAreRefused() throws {
        let loaded = try HandBuiltPackage.load()
        var edits = WorkbookEditTracker()
        edits.notePartStructureChanged()
        #expect(throws: SheetError.self) {
            try XLSXWriter.data(for: loaded.workbook, edits: edits)
        }
    }

    @Test("a sheet whose part cannot be read is refused rather than guessed at")
    func unreadableSheetPartIsRefused() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        // Simulate an entry stored with a method we cannot decode — an AES-encrypted part, say.
        var entry = try #require(workbook.passthrough[HandBuiltPackage.sheet1Path])
        entry.compressionMethod = .other(99)
        workbook.passthrough.upsert(entry)

        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook.sheets.first))
        #expect(throws: SheetError.writeRefused(reason: .unknownCriticalPart)) {
            try XLSXWriter.data(for: workbook, edits: edits)
        }
    }

    // MARK: - workbook.xml

    @Test("renaming a sheet patches one attribute and leaves the rest of workbook.xml alone")
    func renamingASheetIsSurgical() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        try workbook.renameSheet(SheetID(2), to: "Renamed")
        workbook.sheets[2].visibility = .visible

        var edits = WorkbookEditTracker()
        edits.noteWorkbookMetadataChanged()

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let xml = try rewritten.text(OOXMLPart.workbook)
        #expect(xml.contains("name=\"Renamed\""))
        #expect(!xml.contains("name=\"Two\""))
        #expect(xml.contains("name=\"One\""), "the other sheets were disturbed")
        #expect(!xml.contains("state=\"hidden\""), "sheet Three should have been unhidden")
        #expect(xml.contains("calcId=\"171027\""))
        // Every other part is untouched.
        for path in [HandBuiltPackage.sheet1Path, OOXMLPart.styles, OOXMLPart.sharedStrings] {
            #expect(try #require(rewritten[path]).compressedData == #require(loaded.archive[path]).compressedData)
        }
    }

    // MARK: - Styles

    @Test("new styles are appended, leaving existing indexes meaning what they meant")
    func stylesAreAppendOnly() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let original = try loaded.archive.text(OOXMLPart.styles)

        var table = StyleTable(styles: [.default])
        var bold = CellStyle.default
        bold.font.isBold = true
        _ = table.intern(bold)
        workbook.styles = table

        var edits = WorkbookEditTracker()
        edits.noteStylesChanged()

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let patched = try rewritten.text(OOXMLPart.styles)

        #expect(patched.contains("<cellXfs count=\"2\">"))
        #expect(patched.contains("<b/>"))
        // The dxf the conditional format points at by index is still there and still first.
        #expect(patched.contains("<dxfs count=\"1\">"))
        #expect(original.contains("<cellXfs count=\"1\">"))
        // The pre-existing xf is untouched.
        #expect(patched.contains("<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"))
    }
}
