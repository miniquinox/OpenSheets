import DocumentCore
import Foundation
import GridKit
import MiniZip
import SheetFormat
import SheetModel
import SheetStore
import TestSupport
import Testing

/// What a save actually writes, end to end through the real document.
///
/// Wave 2 addendum §2 is a promise about bytes, so it is tested against bytes: type a number into
/// a cell, press ⌘S, and every part of the package that the edit did not touch has to come back
/// out byte-identical — including the two that would silently ruin the file if they were
/// regenerated from the model.
@Suite(.serialized)
@MainActor
struct SaveFidelityTests {
    /// The bug this is the regression for: `Limits.defaultRowHeight` is 24 pt — OpenSheets'
    /// Retina display default — and Excel's is 15. A save that regenerates `<sheetFormatPr>`
    /// because somebody typed a number writes `24` into a file that said `15`, and every row in
    /// the workbook comes back 60% taller.
    @Test func aCellEditRewritesSheetDataAndNothingElse() async throws {
        let harness = try await Harness()
        defer { harness.close() }

        let before = try Data(contentsOf: harness.url)
        _ = harness.model.commitEdit(at: CellRef(a1: "B2")!, text: "12345")
        #expect(await harness.stateSettles(to: .dirty))
        #expect(await harness.model.save())

        let after = try Data(contentsOf: harness.url)
        let originalSheet = try Self.part("xl/worksheets/sheet1.xml", of: before)
        let savedSheet = try Self.part("xl/worksheets/sheet1.xml", of: after)

        #expect(savedSheet.contains("12345"), "the edit did land")
        for element in ["sheetFormatPr", "cols", "sheetViews", "mergeCells"] {
            #expect(
                Self.fragment(element, in: savedSheet) == Self.fragment(element, in: originalSheet),
                "<\(element)> must be copied verbatim, not regenerated"
            )
        }
    }

    /// A column resize is the other direction: it *must* regenerate `<cols>`, and must still not
    /// touch `<sheetFormatPr>`.
    @Test func aColumnResizeRewritesColsAndStillNotSheetFormatPr() async throws {
        let harness = try await Harness()
        defer { harness.close() }

        let before = try Data(contentsOf: harness.url)
        harness.model.resizeColumns(1 ... 1, to: 210)
        #expect(await harness.stateSettles(to: .dirty))
        #expect(await harness.model.save())

        let after = try Data(contentsOf: harness.url)
        let originalSheet = try Self.part("xl/worksheets/sheet1.xml", of: before)
        let savedSheet = try Self.part("xl/worksheets/sheet1.xml", of: after)

        #expect(Self.fragment("cols", in: savedSheet) != Self.fragment("cols", in: originalSheet))
        #expect(
            Self.fragment("sheetFormatPr", in: savedSheet)
                == Self.fragment("sheetFormatPr", in: originalSheet)
        )
    }

    /// PLAN.md §9: *"same file open in two windows"*. One session, one watcher, one undo stack.
    /// Two of each would give the file two opinions about whether it is dirty.
    @Test func openingTheSameFileTwiceSharesOneDocument() async throws {
        let harness = try await Harness()
        defer { harness.close() }
        let again = try await harness.app.openDocument(at: harness.url)
        #expect(again === harness.model)

        // …and through a path that resolves to the same file.
        let indirect = harness.directory
            .appendingPathComponent(".")
            .appendingPathComponent(harness.url.lastPathComponent)
        let third = try await harness.app.openDocument(at: indirect.standardized)
        #expect(third === harness.model)
    }

    /// Addendum §4: A2 refuses to add, remove or reorder a sheet in v0.1, so the controls that
    /// would ask it to are gated off rather than failing at save time.
    @Test func sheetStructureEditingIsGatedOff() {
        #expect(!Flags.sheetStructureEditing, "must stay off until the writer supports it")
    }

    // MARK: - Helpers

    private static func part(_ path: String, of archive: Data) throws -> String {
        let read = try ZipReader.read(archive, name: "test.xlsx")
        let bytes = try read.bytes(of: path)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The literal text of one top-level element, self-closing or not. Deliberately a substring
    /// match rather than a parse: the point is the *bytes*, and a parser would normalise exactly
    /// the differences this is looking for.
    private static func fragment(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)") else { return nil }
        if let close = xml.range(of: "</\(name)>", range: start.lowerBound ..< xml.endIndex) {
            return String(xml[start.lowerBound ..< close.upperBound])
        }
        guard let selfClose = xml.range(of: "/>", range: start.upperBound ..< xml.endIndex) else {
            return nil
        }
        return String(xml[start.lowerBound ..< selfClose.upperBound])
    }
}
