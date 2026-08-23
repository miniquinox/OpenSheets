//
//  PassthroughContractTests.swift
//  SheetFormatTests
//
//  The contract this whole agent exists to satisfy.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel
import Testing

/// The `passthrough/` sidecar, as far as these tests care.
struct PassthroughSidecar: Decodable {
    struct Entry: Decodable {
        var sha256: String
        var crc32: UInt32
        var uncompressedSize: Int
        var method: Int
    }

    var passthroughEntries: [String]
    var sheetLevelElementsThatMustSurvive: [String]?
    var zipEntries: [String: Entry]

    static func load(_ relativePath: String) throws -> PassthroughSidecar {
        try JSONDecoder().decode(PassthroughSidecar.self, from: try FixtureRoot.data(relativePath))
    }
}

@Suite("Passthrough contract")
struct PassthroughContractTests {
    /// Every fixture in the group A7 built to keep this writer honest.
    static let fixtures = [
        "chart.xlsx",
        "comments.xlsx",
        "conditional-format.xlsx",
        "data-validation.xlsx",
        "image.xlsx",
        "kitchen-sink.xlsm",
        "macros.xlsm",
        "pivot-table.xlsx",
    ]

    /// Only these three parts may differ after editing one cell of the first sheet.
    ///
    /// Asserted **per entry**, not with a whole-file hash: a whole-file comparison tells you
    /// something changed and nothing about what, and the failure mode this guards against —
    /// one chart part quietly re-compressed — looks identical to every other failure at that
    /// granularity.
    @Test("editing one cell leaves every other entry byte-identical", arguments: fixtures)
    func onlyTheEditedPartsChange(_ fixture: String) throws {
        let loaded = try FixtureWorkbookLoader.load("passthrough/\(fixture)")
        let sidecar = try PassthroughSidecar.load("passthrough/\(fixture).expected.json")

        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        let sheetPath = try #require(sheet.partPath)

        try workbook.withSheet(sheet.id) { sheet in
            try sheet.cells.setCell(Cell.number(424_242), at: CellRef(row: 0, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        let bytes = try XLSXWriter.data(for: workbook, edits: edits)
        let rewritten = try FixtureArchive(bytes)

        let mayDiffer: Set<String> = [sheetPath, OOXMLPart.sharedStrings, OOXMLPart.calcChain]

        // The archive still holds exactly the same parts, in the same order.
        #expect(rewritten.paths == loaded.archive.paths, "the set or order of parts changed")

        for original in loaded.archive.entries where !mayDiffer.contains(original.path) {
            let after = try #require(rewritten[original.path], "entry '\(original.path)' disappeared")
            #expect(after.crc32 == original.crc32, "CRC changed for '\(original.path)'")
            #expect(after.compressionMethod == original.compressionMethod, "method changed for '\(original.path)'")
            #expect(after.uncompressedSize == original.uncompressedSize, "size changed for '\(original.path)'")
            #expect(
                after.compressedData == original.compressedData,
                "stored bytes changed for '\(original.path)' — it was re-compressed rather than copied"
            )

            // Independent of our own reader: compare the inflated bytes against the hash A7
            // recorded when the fixture was built.
            if let expected = sidecar.zipEntries[original.path] {
                let inflated = try rewritten.contents(original.path)
                #expect(
                    SavedFileFingerprint.hash(inflated) == expected.sha256,
                    "content hash changed for '\(original.path)'"
                )
                #expect(expected.crc32 == after.crc32)
            }
        }

        // The sidecar's own list, which is the narrower claim A7 makes.
        for path in sidecar.passthroughEntries {
            let before = try #require(loaded.archive[path])
            let after = try #require(rewritten[path])
            #expect(before.compressedData == after.compressedData)
        }
    }

    @Test("sheet-level elements survive the rewrite of the part they live in", arguments: fixtures)
    func sheetLevelElementsSurvive(_ fixture: String) throws {
        let loaded = try FixtureWorkbookLoader.load("passthrough/\(fixture)")
        let sidecar = try PassthroughSidecar.load("passthrough/\(fixture).expected.json")
        let mustSurvive = sidecar.sheetLevelElementsThatMustSurvive ?? []

        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        let sheetPath = try #require(sheet.partPath)
        let before = try WorksheetPartScanner.scan(try loaded.archive.text(sheetPath), part: sheetPath)

        try workbook.withSheet(sheet.id) { sheet in
            try sheet.cells.setCell(Cell.number(424_242), at: CellRef(row: 0, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let after = try WorksheetPartScanner.scan(try rewritten.text(sheetPath), part: sheetPath)

        for element in mustSurvive {
            #expect(after.childNames.contains(element), "<\(element)> was dropped from \(sheetPath)")
        }

        // Nothing else went missing either, and nothing was duplicated.
        for child in before.children where child.localName != "sheetData" {
            let expected = before.children.count { $0.localName == child.localName }
            let actual = after.children.count { $0.localName == child.localName }
            #expect(actual == expected, "<\(child.localName)> count changed in \(sheetPath)")
        }

        // Copied elements are copied, not re-serialised.
        for child in after.children
            where !WorksheetPartWriter.modelledElements.contains(child.localName) {
            #expect(
                before.children.contains { $0.text == child.text },
                "<\(child.localName)> was rewritten rather than copied verbatim"
            )
        }

        // `CT_Worksheet` is a sequence: out of order and Excel repairs the file by discarding.
        let positions = after.children.map { WorksheetChildOrder.position(of: $0.localName) }
        #expect(positions == positions.sorted(), "children are not in CT_Worksheet order: \(after.children.map(\.localName))")

        // The root tag, with its namespace declarations, is the original's.
        #expect(after.rootOpenTag == before.rootOpenTag)
    }

    @Test("the edit actually lands", arguments: fixtures)
    func theEditIsWritten(_ fixture: String) throws {
        let loaded = try FixtureWorkbookLoader.load("passthrough/\(fixture)")
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        let sheetPath = try #require(sheet.partPath)

        try workbook.withSheet(sheet.id) { sheet in
            try sheet.cells.setCell(Cell.text("edited by OpenSheets"), at: CellRef(row: 0, column: 0))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]))

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))

        var reloaded = Sheet(id: sheet.id, name: sheet.name)
        reloaded.partPath = sheetPath
        var strings: [String] = []
        if rewritten[OOXMLPart.sharedStrings] != nil {
            let scanned = try WorksheetPartScanner.scan(
                try rewritten.text(OOXMLPart.sharedStrings), part: OOXMLPart.sharedStrings
            )
            strings = scanned.children.filter { $0.localName == "si" }.map { SharedStringTable.flatten($0.text) }
        }
        try FixtureWorkbookLoader.populate(&reloaded, from: try rewritten.text(sheetPath), strings: strings)

        #expect(reloaded.cells[CellRef(row: 0, column: 0)]?.value == .text("edited by OpenSheets"))
    }

    @Test("every other cell in the edited sheet round-trips unchanged", arguments: fixtures)
    func untouchedCellsRoundTrip(_ fixture: String) throws {
        let loaded = try FixtureWorkbookLoader.load("passthrough/\(fixture)")
        let workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)
        let sheetPath = try #require(sheet.partPath)
        let originalCells = sheet.cells

        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: sheet)
        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))

        var reloaded = Sheet(id: sheet.id, name: sheet.name)
        reloaded.partPath = sheetPath
        var strings: [String] = []
        if rewritten[OOXMLPart.sharedStrings] != nil {
            let scanned = try WorksheetPartScanner.scan(
                try rewritten.text(OOXMLPart.sharedStrings), part: OOXMLPart.sharedStrings
            )
            strings = scanned.children.filter { $0.localName == "si" }.map { SharedStringTable.flatten($0.text) }
        }
        try FixtureWorkbookLoader.populate(&reloaded, from: try rewritten.text(sheetPath), strings: strings)

        #expect(reloaded.cells.count == originalCells.count)
        originalCells.forEachCell(in: .entireSheet) { ref, cell in
            #expect(reloaded.cells[ref]?.value == cell.value, "\(ref.a1String) changed")
            #expect(reloaded.cells[ref]?.formula == cell.formula, "\(ref.a1String) formula changed")
        }
    }
}
