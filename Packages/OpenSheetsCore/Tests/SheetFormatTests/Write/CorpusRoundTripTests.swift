//
//  CorpusRoundTripTests.swift
//  SheetFormatTests
//
//  `parse(write(parse(f))) == parse(f)` over the whole non-hostile corpus.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel
import Testing

@Suite("Corpus round trip")
struct CorpusRoundTripTests {
    /// Every non-hostile `.xlsx`/`.xlsm` in the corpus, found on disk rather than listed, so a
    /// fixture A7 adds later is covered without anybody remembering to add it here.
    ///
    /// `hostile/` is excluded because those files are supposed to be rejected, and `perf/`
    /// because its point is elapsed time, not fidelity.
    static let fixtures: [String] = {
        let groups = ["basic", "formats", "formulas", "structure", "passthrough"]
        var result: [String] = []
        for group in groups {
            let directory = FixtureRoot.url(group)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".xlsx") || name.hasSuffix(".xlsm") {
                result.append("\(group)/\(name)")
            }
        }
        return result
    }()

    /// Guards the guard: a fixture list that silently came back empty would make every test in
    /// this suite pass by doing nothing at all.
    @Test("the corpus was actually found")
    func theCorpusIsNotEmpty() {
        let found = Self.fixtures
        #expect(found.count >= 40, "only found \(found.count) fixtures under \(FixtureRoot.url.path)")
    }

    @Test("a save with nothing dirty changes no entry at all", arguments: fixtures)
    func aNoOpSaveIsANoOp(_ path: String) throws {
        let loaded = try FixtureWorkbookLoader.load(path)
        let rewritten = try FixtureArchive(
            try XLSXWriter.data(for: loaded.workbook, edits: WorkbookEditTracker())
        )

        #expect(rewritten.paths == loaded.archive.paths)
        for original in loaded.archive.entries {
            let after = try #require(rewritten[original.path])
            #expect(after.compressedData == original.compressedData, "\(original.path) in \(path)")
            #expect(after.crc32 == original.crc32)
            #expect(after.compressionMethod == original.compressionMethod)
        }
    }

    @Test("cells survive read → edit → write → read", arguments: fixtures)
    func cellsRoundTrip(_ path: String) throws {
        let loaded = try FixtureWorkbookLoader.load(path)
        let workbook = loaded.workbook

        // Mark every sheet dirty so every worksheet part is genuinely re-serialised, which is
        // the case where fidelity can be lost. Regions stay at the default (`cells`), because
        // that is the production path: a cell edit must not perturb column widths or views.
        var edits = WorkbookEditTracker()
        for sheet in workbook.sheets { edits.noteCellsChanged(in: sheet) }

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: workbook, edits: edits))
        let reloaded = try FixtureWorkbookLoader.load(archive: rewritten, isMacroEnabled: path.hasSuffix(".xlsm"))

        #expect(reloaded.workbook.sheets.count == workbook.sheets.count)
        for (before, after) in zip(workbook.sheets, reloaded.workbook.sheets) {
            #expect(after.name == before.name)
            #expect(after.id == before.id)
            #expect(after.visibility == before.visibility)
            #expect(after.merges == before.merges)
            #expect(after.autoFilter == before.autoFilter)
            #expect(after.cells.count == before.cells.count, "\(path) sheet '\(before.name)' cell count")
            #expect(after.usedRange == before.usedRange, "\(path) sheet '\(before.name)' used range")

            before.cells.forEachCell(in: .entireSheet) { ref, cell in
                let round = after.cells[ref]
                #expect(round?.value == cell.value, "\(path) \(before.name)!\(ref.a1String) value")
                #expect(round?.formula == cell.formula, "\(path) \(before.name)!\(ref.a1String) formula")
                #expect(round?.styleID == cell.styleID, "\(path) \(before.name)!\(ref.a1String) style")
            }
            #expect(after.arrayFormulaRanges == before.arrayFormulaRanges, "\(path) array regions")
            #expect(
                after.hyperlinks.keys.sorted() == before.hyperlinks.keys.sorted(),
                "\(path) sheet '\(before.name)' hyperlinks"
            )
        }
        _ = loaded
    }

    @Test("no top-level worksheet element is lost when the part is rewritten", arguments: fixtures)
    func noSheetElementIsLost(_ path: String) throws {
        let loaded = try FixtureWorkbookLoader.load(path)
        var edits = WorkbookEditTracker()
        for sheet in loaded.workbook.sheets { edits.noteCellsChanged(in: sheet) }

        let rewritten = try FixtureArchive(try XLSXWriter.data(for: loaded.workbook, edits: edits))

        for sheet in loaded.workbook.sheets {
            guard let sheetPath = sheet.partPath else { continue }
            let before = try WorksheetPartScanner.scan(try loaded.archive.text(sheetPath), part: sheetPath)
            let after = try WorksheetPartScanner.scan(try rewritten.text(sheetPath), part: sheetPath)

            for name in before.childNames where name != "sheetData" {
                #expect(after.childNames.contains(name), "<\(name)> lost from \(sheetPath) in \(path)")
            }
            // Anything the writer does not generate came through byte for byte.
            for child in after.children where !WorksheetPartWriter.modelledElements.contains(child.localName) {
                #expect(
                    before.children.contains { $0.text == child.text },
                    "<\(child.localName)> in \(sheetPath) of \(path) was rewritten rather than copied"
                )
            }
            let positions = after.children.map { WorksheetChildOrder.position(of: $0.localName) }
            #expect(positions == positions.sorted(), "\(sheetPath) in \(path) is out of CT_Worksheet order")
            #expect(after.rootOpenTag == before.rootOpenTag, "\(sheetPath) in \(path) lost its namespace declarations")
        }
    }
}
