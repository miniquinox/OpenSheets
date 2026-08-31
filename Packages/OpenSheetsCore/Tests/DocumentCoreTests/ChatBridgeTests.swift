@testable import DocumentCore
import Foundation
import SheetChat
import SheetModel
import SheetStore
import Testing
import TestSupport

/// The bridge against a **live** `DocumentModel` — the half the fake in `SheetChatTests` cannot
/// cover. What is pinned here is the in-process decision itself: reads see unsaved edits, writes
/// are one named undo step through the typing pipeline, and nothing touches the disk.
@MainActor
struct ChatBridgeTests {
    /// Sales sheet with a header row, a numeric column, a formula, and a second sheet — the
    /// smallest workbook that exercises every bridge path.
    private func makeModel() throws -> DocumentModel {
        let workbook = try WorkbookBuilder()
            .sheet("Sales")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Region"), .text("Units"), .text("Revenue")],
                [.text("North"), .number(10), .number(1200)],
                [.text("South"), .number(20), .number(3400)],
            ])
            .formula("C4", "SUM(C2:C3)", cached: .number(4600))
            .sheet("Summary")
            .partPath("xl/worksheets/sheet2.xml", relationshipID: "rId2")
            .cell("A1", .text("Total"))
            .build()
        let url = URL(fileURLWithPath: "/tmp/chat-bridge-tests/q4.xlsx")
        let reader = DocumentWorkbookReader()
        let session = DocumentSession(
            url: url,
            workbook: workbook,
            io: WorkbookIO(reader: reader),
            suppressor: SelfWriteSuppressor(),
            options: DocumentSession.Options(autoRefresh: false, snapshotsEnabled: false)
        )
        return DocumentModel(
            url: url,
            workspaceURL: url.deletingLastPathComponent(),
            workbook: workbook,
            session: session,
            reader: reader,
            writer: nil,
            autoRefresh: false
        )
    }

    // MARK: - Overview

    @Test func theOverviewDescribesWhatIsOnScreen() throws {
        let model = try makeModel()
        let overview = DocumentChatBridge(model: model).overview()
        #expect(overview.fileName == "q4.xlsx")
        #expect(overview.activeSheetName == "Sales")
        #expect(overview.sheetNames == ["Sales", "Summary"])
        #expect(overview.usedRangeA1 == "A1:C4")
        #expect(overview.selectionA1 == "A1")
        #expect(overview.headerCells == ["A: Region", "B: Units", "C: Revenue"])
        #expect(overview.isEditable)
    }

    // MARK: - Reads

    @Test func readsComeFromMemoryNotFromDisk() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        // An unsaved edit — the file at the model's URL does not even exist.
        #expect(model.commitEdit(at: try #require(CellRef(a1: "B2")), text: "99"))
        let slice = try bridge.readRange(
            sheetName: nil, rangeA1: "A2:C2", maxRows: 10, maxColumns: 10
        )
        #expect(slice.rows.first?.cells == ["North", "99", "1200"])
    }

    @Test func aFormulaCellReadsAsItsValue() throws {
        let model = try makeModel()
        let slice = try DocumentChatBridge(model: model).readRange(
            sheetName: nil, rangeA1: "C4", maxRows: 1, maxColumns: 1
        )
        #expect(slice.rows.first?.cells == ["4600"])
    }

    @Test func theWindowClampsAndCountsOnlyRealRows() throws {
        let model = try makeModel()
        // A whole-column-sized ask: the window caps, and the truncation counts the rows that
        // exist (4) minus the rows shown (2) — not the million blank ones below.
        let slice = try DocumentChatBridge(model: model).readRange(
            sheetName: nil, rangeA1: "A1:A1000", maxRows: 2, maxColumns: 2
        )
        #expect(slice.rangeA1 == "A1:A2")
        #expect(slice.rows.count == 2)
        #expect(slice.truncatedRowCount == 2)
        #expect(slice.truncatedColumnCount == 0)
    }

    @Test func aNamedSheetIsReadAndAnUnknownOneThrows() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        let slice = try bridge.readRange(
            sheetName: "Summary", rangeA1: "A1", maxRows: 1, maxColumns: 1
        )
        #expect(slice.sheetName == "Summary")
        #expect(slice.rows.first?.cells == ["Total"])
        #expect(throws: SheetError.self) {
            try bridge.readRange(sheetName: "Nope", rangeA1: "A1", maxRows: 1, maxColumns: 1)
        }
    }

    // MARK: - Writes

    @Test func aBatchIsOneUndoStepNamedForTheAgent() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        let outcome = try bridge.applyEdits(
            [
                ChatCellEdit(refA1: "D1", content: "Growth"),
                ChatCellEdit(refA1: "D2", content: "=B2*2"),
            ],
            sheetName: nil
        )
        #expect(outcome.appliedCount == 2)
        #expect(outcome.appliedRangeA1 == "D1:D2")
        #expect(outcome.refusals.isEmpty)
        #expect(model.undoName == "Apple Intelligence")
        // The formula went through the engine on the way in.
        #expect(model.workbook[model.activeSheetID]?.cells[try #require(CellRef(a1: "D2"))]?.value == .number(20))

        model.undo()
        #expect(model.workbook[model.activeSheetID]?.cells[try #require(CellRef(a1: "D1"))] == nil)
        #expect(model.workbook[model.activeSheetID]?.cells[try #require(CellRef(a1: "D2"))] == nil)
    }

    @Test func aBadFormulaIsRefusedWhileItsNeighboursLand() throws {
        let model = try makeModel()
        let outcome = try DocumentChatBridge(model: model).applyEdits(
            [
                ChatCellEdit(refA1: "E1", content: "ok"),
                ChatCellEdit(refA1: "E2", content: "=SUM("),
            ],
            sheetName: nil
        )
        #expect(outcome.appliedCount == 1)
        #expect(outcome.refusals.count == 1)
        #expect(outcome.refusals.first?.contains("E2") == true)
        #expect(model.workbook[model.activeSheetID]?.cells[try #require(CellRef(a1: "E1"))]?.value == .text("ok"))
    }

    @Test func aGarbageReferenceIsRefusedAtTheBridge() throws {
        let model = try makeModel()
        let outcome = try DocumentChatBridge(model: model).applyEdits(
            [ChatCellEdit(refA1: "not a ref", content: "1")],
            sheetName: nil
        )
        #expect(outcome.appliedCount == 0)
        #expect(outcome.refusals.first?.contains("not a cell reference") == true)
    }

    @Test func writesReachANamedSheetWithoutSwitchingToIt() throws {
        let model = try makeModel()
        let salesID = model.activeSheetID
        let outcome = try DocumentChatBridge(model: model).applyEdits(
            [ChatCellEdit(refA1: "B1", content: "42")],
            sheetName: "Summary"
        )
        #expect(outcome.appliedCount == 1)
        #expect(model.activeSheetID == salesID, "the user's view does not jump")
        let summary = model.workbook.sheet(named: "Summary")
        #expect(summary?.cells[try #require(CellRef(a1: "B1"))]?.value == .number(42))
    }

    // MARK: - Append

    @Test func appendLandsBelowTheDataAsOneUndoStep() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        let outcome = try bridge.appendRow(["Imaginary", "5", "0"])
        #expect(outcome.rowNumber == 5, "the data ends at row 4; the document picked 5")
        #expect(outcome.appliedCount == 3)
        let sheet = model.workbook[model.activeSheetID]
        #expect(sheet?.cells[try #require(CellRef(a1: "A5"))]?.value == .text("Imaginary"))
        #expect(sheet?.cells[try #require(CellRef(a1: "B5"))]?.value == .number(5))
        #expect(model.undoName == "Apple Intelligence")
        model.undo()
        #expect(model.workbook[model.activeSheetID]?.usedRange == CellRange(a1: "A1:C4"))
    }

    @Test func consecutiveAppendsStack() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        #expect(try bridge.appendRow(["one"]).rowNumber == 5)
        #expect(try bridge.appendRow(["two"]).rowNumber == 6)
        #expect(try bridge.appendRow(["three"]).rowNumber == 7)
    }

    @Test func theOverviewNamesTheNextEmptyRow() throws {
        let model = try makeModel()
        #expect(DocumentChatBridge(model: model).overview().nextEmptyRow == 5)
    }

    // MARK: - Calculate

    @Test func evaluateComputesAgainstTheLiveWorkbookAndWritesNothing() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        #expect(try bridge.evaluate("=SUM(C2:C3)") == "4600")
        #expect(try bridge.evaluate("SUM(B2:B3)") == "30", "the leading '=' is optional")
        // An unsaved edit is part of the answer — the calculator sees the screen, not the disk.
        #expect(model.commitEdit(at: try #require(CellRef(a1: "B2")), text: "100"))
        #expect(try bridge.evaluate("=SUM(B2:B3)") == "120")
        #expect(!model.canUndo || model.undoName != "Apple Intelligence", "nothing was written")
        #expect(model.workbook[model.activeSheetID]?.usedRange == CellRange(a1: "A1:C4"))
    }

    @Test func evaluateReportsErrorsAsTokensNotThrows() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)
        #expect(try bridge.evaluate("=NOSUCHFUNCTION(1)") == "#NAME?")
    }

    // MARK: - Find

    @Test func findSearchesValuesAndFormulasActiveSheetFirst() throws {
        let model = try makeModel()
        let bridge = DocumentChatBridge(model: model)

        let byValue = bridge.find("North", maxMatches: 10)
        #expect(byValue.matches.map(\.refA1) == ["A2"])
        #expect(!byValue.truncated)

        let byFormula = bridge.find("SUM(C2", maxMatches: 10)
        #expect(byFormula.matches.map(\.refA1) == ["C4"])

        // "Total" lives on Summary; the search still finds it after walking Sales first.
        let crossSheet = bridge.find("total", maxMatches: 10)
        #expect(crossSheet.matches.first?.sheetName == "Summary")
    }

    @Test func findStopsAtTheCapAndSaysSo() throws {
        let model = try makeModel()
        let result = DocumentChatBridge(model: model).find("o", maxMatches: 2)
        #expect(result.matches.count == 2)
        #expect(result.truncated)
    }
}
