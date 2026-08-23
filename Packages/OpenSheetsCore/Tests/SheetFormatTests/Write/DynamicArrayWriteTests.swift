//
//  DynamicArrayWriteTests.swift
//  SheetFormatTests
//
//  What the writer does with a spill it can represent, and what it refuses to do with metadata
//  it cannot.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel
import Testing

@Suite("Dynamic arrays on write")
struct DynamicArrayWriteTests {
    // MARK: - Uncomputed cells never become fabricated errors

    @Test("a cell we could not compute is written back as <f> with no <v>")
    func anUncomputedCellKeepsItsValueOutOfTheFile() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)

        // What a recalculation leaves behind for `<f>MMULT(…)</f>` with no cached value: a
        // placeholder so the screen says "uncomputed", and the flag that says it is ours.
        try workbook.withSheet(sheet.id) { target in
            try target.cells.setCell(
                Cell(
                    value: .error(.unknownName),
                    formula: "MMULT(B1:B2,C1:C2)",
                    flags: [.uncomputed, .staleCache, .unsupportedFormula]
                ),
                at: CellRef(row: 0, column: 0)
            )
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let xml = try rewritten.text(HandBuiltPackage.sheet1Path)
        let cell = try #require(DynamicArrayWriteTests.element(forCell: "A1", in: xml))

        #expect(cell.contains("<f>"), "the formula is the user's and survives")
        #expect(cell.contains("MMULT"))
        #expect(!cell.contains("<v>"), "our placeholder must not become their cached error")
        #expect(!cell.contains("#NAME?"))
    }

    @Test("a genuine cached error is still written")
    func aRealErrorValueIsNotSuppressed() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        try workbook.withSheet(sheet.id) { target in
            try target.cells.setCell(
                Cell(value: .error(.divideByZero), formula: "1/0"), at: CellRef(row: 0, column: 0)
            )
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))
        let xml = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
            .text(HandBuiltPackage.sheet1Path)
        let cell = try #require(DynamicArrayWriteTests.element(forCell: "A1", in: xml))
        #expect(cell.contains("#DIV/0!"), "this one we computed, so it is a fact about the workbook")
    }

    // MARK: - Spill regions

    @Test("a spill anchor is written as t=\"array\" over its region")
    func aSpillAnchorBecomesAnArrayFormula() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        try workbook.withSheet(sheet.id) { target in
            try target.cells.setCell(
                Cell(value: .number(1), formula: "SEQUENCE(1,3)", flags: [.spillAnchor, .arrayFormula]),
                at: CellRef(a1: "A1")!
            )
            try target.cells.setCell(
                Cell(value: .number(2), flags: [.spilledInto, .arrayFormula]), at: CellRef(a1: "B1")!
            )
            try target.cells.setCell(
                Cell(value: .number(3), flags: [.spilledInto, .arrayFormula]), at: CellRef(a1: "C1")!
            )
            target.arrayFormulaRanges[CellRef(a1: "A1")!] = CellRange(a1: "A1:C1")!
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))
        let xml = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
            .text(HandBuiltPackage.sheet1Path)

        let anchor = try #require(DynamicArrayWriteTests.element(forCell: "A1", in: xml))
        #expect(anchor.contains("t=\"array\""))
        #expect(anchor.contains("ref=\"A1:C1\""))
        #expect(anchor.contains("_xlfn.SEQUENCE"), "the stored spelling, or Excel shows #NAME?")

        // The spilled cells carry values and no formula, which is how Excel stores them too.
        let spilled = try #require(DynamicArrayWriteTests.element(forCell: "B1", in: xml))
        #expect(spilled.contains("<v>2</v>"))
        #expect(!spilled.contains("<f"))
    }

    // MARK: - The refusal

    @Test("rewriting a sheet whose dynamic-array metadata we cannot reproduce is refused")
    func aSheetWithCellMetadataIsRefusedRatherThanDegraded() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        try workbook.withSheet(sheet.id) { target in
            // What the reader sets when `<c r="B4" cm="1">` comes out of a real Excel file.
            try target.cells.setCell(
                Cell(value: .number(5), flags: [.hasCellMetadata]), at: CellRef(a1: "B4")!
            )
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        var thrown: SheetError?
        do {
            _ = try XLSXWriter.data(for: workbook, edits: edits)
        } catch {
            thrown = error
        }
        let refusal = try #require(thrown, "saving must refuse rather than silently drop cm/vm")
        #expect(refusal.code == "core.notImplemented")
        #expect(refusal.message.contains("B4"), "the refusal has to name the cell it is protecting")
        #expect(refusal.message.contains("dynamic array"))
    }

    @Test("the refusal can be waived by a caller that has told the user what it costs")
    func degradingIsPossibleButNeverTheDefault() throws {
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        try workbook.withSheet(sheet.id) { target in
            try target.cells.setCell(
                Cell(value: .number(5), flags: [.hasCellMetadata]), at: CellRef(a1: "B4")!
            )
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        let options = XLSXWriteOptions(dynamicArrayMetadata: .degrade)
        let data = try XLSXWriter.data(for: workbook, edits: edits, options: options)
        #expect(try FixtureArchive(data).text(HandBuiltPackage.sheet1Path).contains("r=\"B4\""))
        #expect(XLSXWriteOptions.standard.dynamicArrayMetadata == .refuse)
    }

    @Test("a sheet nobody edited is copied verbatim, metadata and all")
    func anUntouchedSheetIsNeverAtRisk() throws {
        // The refusal only fires when we would *regenerate* the part. A workbook full of
        // dynamic arrays is still saveable as long as the edit was somewhere else.
        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)
        let third = try #require(workbook.sheets.first { $0.name == "Three" })
        try workbook.withSheet(first.id) { target in
            try target.cells.setCell(
                Cell(value: .number(5), flags: [.hasCellMetadata]), at: CellRef(a1: "B4")!
            )
        }
        try workbook.withSheet(third.id) { target in
            try target.cells.setCell(Cell.number(99), at: CellRef(row: 5, column: 5))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[third.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let before = try #require(loaded.archive[HandBuiltPackage.sheet1Path])
        let after = try #require(rewritten[HandBuiltPackage.sheet1Path])
        #expect(after.compressedData == before.compressedData)
    }

    // MARK: - Reading

    @Test("cm and vm on a cell are recorded, because dropping them silently is the bug")
    func theReaderNoticesCellMetadata() async throws {
        // A real package with `cm`/`vm` spliced into two of its cells, so the reader is being
        // asked the same question Excel's own output would ask it.
        let archive = try FixtureArchive(try HandBuiltPackage.archiveData())
        let patched = try archive.text(HandBuiltPackage.sheet1Path)
            .replacingOccurrences(of: "<c r=\"A2\">", with: "<c r=\"A2\" cm=\"1\">")
            .replacingOccurrences(of: "<c r=\"B2\">", with: "<c r=\"B2\" vm=\"2\">")
        var entries = archive.entries
        for index in entries.indices where entries[index].path == HandBuiltPackage.sheet1Path {
            entries[index] = ZipWriter.entry(path: HandBuiltPackage.sheet1Path, contents: Data(patched.utf8))
        }
        let workbook = try await XLSXReader.read(try ZipWriter.archive(entries), name: "metadata.xlsx").workbook
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.cells[CellRef(a1: "A2")!]?.flags.contains(.hasCellMetadata) == true)
        #expect(sheet.cells[CellRef(a1: "B2")!]?.flags.contains(.hasCellMetadata) == true)
        #expect(sheet.cells[CellRef(a1: "A3")!]?.flags.contains(.hasCellMetadata) == false)
    }

    /// The `<c …>…</c>` element for one address, or `nil`.
    private static func element(forCell address: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<c r=\"\(address)\"") else { return nil }
        let rest = xml[start.lowerBound...]
        if let selfClose = rest.range(of: "/>"), let open = rest.range(of: ">"),
           selfClose.lowerBound < open.lowerBound || selfClose.lowerBound == rest.index(before: open.upperBound) {
            return String(rest[..<selfClose.upperBound])
        }
        guard let close = rest.range(of: "</c>") else { return nil }
        return String(rest[..<close.upperBound])
    }
}
