import DocumentCore
import Foundation
import GridKit
import SheetFormat
import SheetModel
import SheetStore
import TestSupport
import Testing

/// PLAN.md §1.2 — the loop the app exists for, walked step by step against a **real file edited by
/// a real external process**.
///
/// The external writer is a `/bin/sh` subprocess doing an atomic replace with `python3`, not
/// `Data.write(to:)` from inside the test. That distinction is the whole point: `Data.write` on
/// the same thread produces a write the watcher sees through a code path we control, whereas an
/// out-of-process atomic replace is what Claude Code, `openpyxl`, Excel and every other real
/// writer actually does — and it is the one that used to be missed, because the file descriptor
/// the watcher holds still points at the old inode afterwards.
@Suite(.serialized)
@MainActor
struct CoreLoopTests {
    // MARK: - Step 1: open

    @Test func opensAWorkbookAndPaints() async throws {
        let harness = try await Harness()
        #expect(harness.model.workbook.sheets.count == 1)
        #expect(harness.model.syncState == .synced)
        #expect(harness.model.activeSheetID == harness.model.workbook.sheets[0].id)
        harness.close()
    }

    // MARK: - Steps 5 and 6: the pill and the diff

    @Test func anExternalChangeRaisesThePillWithAnAccurateDiff() async throws {
        let harness = try await Harness(autoRefresh: false)

        try await harness.externalEdit { workbook in
            try workbook.withSheet(workbook.sheets[0].id) { sheet in
                try sheet.cells.setCell(.number(999), at: CellRef(a1: "B2")!)
            }
        }
        try await harness.waitFor { $0.syncState == .stale }
        try await harness.waitFor { $0.changeSet != nil }

        let changeSet = try #require(harness.model.changeSet)
        #expect(harness.model.syncPhase == .pill)
        #expect(changeSet.notice.headline == "Changed on disk")
        #expect(changeSet.notice.cellCount == 1)
        #expect(changeSet.notice.sheetCount == 1)
        let row = try #require(changeSet.changes.first)
        #expect(row.refLabel == "B2")
        #expect(row.after == "999")

        // Step 6: the pill *becomes* the panel. Same surface, same data, no second fetch.
        harness.model.showDiffPanel()
        #expect(harness.model.syncPhase == .panel)
        #expect(harness.model.changeSet?.changes.count == 1)

        harness.close()
    }

    // MARK: - Step 7: refresh, flash, feed

    @Test func refreshAppliesTheChangeAndRecordsIt() async throws {
        let harness = try await Harness(autoRefresh: false)
        let sheetID = harness.model.workbook.sheets[0].id

        try await harness.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(129.6), at: CellRef(a1: "B2")!)
                try sheet.cells.setCell(.text("added by the agent"), at: CellRef(a1: "D9")!)
            }
        }
        try await harness.waitFor { $0.syncState == .stale }

        await harness.model.refresh()
        try await harness.waitFor { $0.syncState == .synced }

        let sheet = try #require(harness.model.workbook[sheetID])
        #expect(sheet.cells[CellRef(a1: "B2")!]?.value == .number(129.6))
        #expect(sheet.cells[CellRef(a1: "D9")!]?.value == .text("added by the agent"))
        // Step 7's second half: the sidebar keeps a session feed so the user can retrace what the
        // agent did.
        #expect(harness.model.feed.count == 1)
        #expect(harness.model.feed[0].cellCount == 2)
        #expect(harness.model.syncPhase == .hidden)

        harness.close()
    }

    @Test func autoRefreshAppliesWithoutBeingAsked() async throws {
        let harness = try await Harness(autoRefresh: true)
        let sheetID = harness.model.workbook.sheets[0].id

        try await harness.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(42), at: CellRef(a1: "C3")!)
            }
        }
        try await harness.waitFor(timeout: .seconds(10)) {
            $0.workbook[sheetID]?.cells[CellRef(a1: "C3")!]?.value == .number(42)
        }
        #expect(harness.model.syncState == .synced)
        harness.close()
    }

    // MARK: - Step 8 and §6.2: our own saves do not loop

    @Test func ourOwnSaveDoesNotTriggerARefresh() async throws {
        let harness = try await Harness()
        let sheetID = harness.model.workbook.sheets[0].id

        _ = harness.model.commitEdit(at: CellRef(a1: "B2")!, text: "7")
        #expect(await harness.stateSettles(to: .dirty))
        let saved = await harness.model.save()
        #expect(saved)

        // Give the watcher longer than its debounce plus its stability window. If self-write
        // suppression were missing this is exactly where the refresh loop would start.
        try await Task.sleep(for: .milliseconds(900))
        #expect(harness.model.syncState == .synced)
        #expect(harness.model.changeSet == nil)
        #expect(harness.model.feed.isEmpty)

        let reread = try await DocumentWorkbookReader.read(harness.url)
        #expect(reread[sheetID]?.cells[CellRef(a1: "B2")!]?.value == .number(7))
        harness.close()
    }

    // MARK: - §1.3: the conflict, and all three ways out

    @Test func conflictKeepMineWritesMemoryOverTheFile() async throws {
        let harness = try await Harness(autoRefresh: true)
        let sheetID = harness.model.workbook.sheets[0].id

        _ = harness.model.commitEdit(at: CellRef(a1: "A1")!, text: "mine")
        #expect(await harness.stateSettles(to: .dirty))
        try await harness.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.text("theirs"), at: CellRef(a1: "A1")!)
            }
        }
        try await harness.waitFor { $0.syncState == .conflict }
        #expect(harness.model.changeSet?.notice.localEditCount == 1)

        await harness.model.resolveConflict(.keepMine)
        try await harness.waitFor { $0.syncState == .synced }

        let disk = try await DocumentWorkbookReader.read(harness.url)
        #expect(disk[sheetID]?.cells[CellRef(a1: "A1")!]?.value == .text("mine"))
        harness.close()
    }

    @Test func conflictTakeDiskDiscardsLocalEditsAndReloads() async throws {
        let harness = try await Harness(autoRefresh: true)
        let sheetID = harness.model.workbook.sheets[0].id

        _ = harness.model.commitEdit(at: CellRef(a1: "A1")!, text: "mine")
        #expect(await harness.stateSettles(to: .dirty))
        try await harness.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.text("theirs"), at: CellRef(a1: "A1")!)
            }
        }
        try await harness.waitFor { $0.syncState == .conflict }

        // Nothing is lost silently: the pre-refresh snapshot is taken by the state machine's own
        // `captureSnapshot(.preRefresh)` effect, so the discarded version is still recoverable.
        let before = await harness.model.snapshots().count

        await harness.model.resolveConflict(.takeDisk)
        try await harness.waitFor { $0.workbook[sheetID]?.cells[CellRef(a1: "A1")!]?.value == .text("theirs") }
        try await harness.waitFor { $0.syncState == .synced }
        #expect(!harness.model.canUndo, "a refresh clears the undo stack")

        let after = await harness.model.snapshots().count
        #expect(after > before, "take-disk must leave a snapshot behind, not just discard")
        harness.close()
    }

    @Test func conflictCompareResolvesNothing() async throws {
        let harness = try await Harness(autoRefresh: true)
        let sheetID = harness.model.workbook.sheets[0].id

        _ = harness.model.commitEdit(at: CellRef(a1: "A1")!, text: "mine")
        #expect(await harness.stateSettles(to: .dirty))
        try await harness.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.text("theirs"), at: CellRef(a1: "A1")!)
            }
        }
        try await harness.waitFor { $0.syncState == .conflict }

        await harness.model.resolveConflict(.compare)
        #expect(harness.model.syncState == .conflict, "compare decides nothing")
        #expect(harness.model.syncPhase == .panel)
        #expect(harness.model.workbook[sheetID]?.cells[CellRef(a1: "A1")!]?.value == .text("mine"))

        let disk = try await DocumentWorkbookReader.read(harness.url)
        #expect(disk[sheetID]?.cells[CellRef(a1: "A1")!]?.value == .text("theirs"))
        harness.close()
    }

    // MARK: - §9: five documents at once

    @Test func fiveDocumentsDoNotCrossTalk() async throws {
        var harnesses: [Harness] = []
        for index in 0 ..< 5 {
            harnesses.append(try await Harness(name: "book-\(index).xlsx", seed: Double(index)))
        }
        defer { for harness in harnesses { harness.close() } }

        for (index, harness) in harnesses.enumerated() {
            _ = harness.model.commitEdit(at: CellRef(a1: "A1")!, text: "\(index * 11)")
        }
        for (index, harness) in harnesses.enumerated() {
            #expect(harness.model.workbook.sheets[0].cells[CellRef(a1: "A1")!]?.value == .number(Double(index * 11)))
            let saved = await harness.model.save()
            #expect(saved, "document \(index) failed to save")
        }
        for (index, harness) in harnesses.enumerated() {
            let disk = try await DocumentWorkbookReader.read(harness.url)
            #expect(disk.sheets[0].cells[CellRef(a1: "A1")!]?.value == .number(Double(index * 11)))
        }
    }

    // MARK: - The acceptance criterion about leaks

    @Test func closingADocumentDeallocatesItsModel() async throws {
        // A separate scope so nothing in this function keeps a reference alive.
        weak var weakModel: DocumentModel?
        let store = try Harness.makeStore()
        do {
            let harness = try await Harness(store: store)
            weakModel = harness.model
            #expect(weakModel != nil)
            harness.close()
        }
        // The pump task is cancelled by `close()`, but ARC needs the surrounding autorelease pool
        // and the cancelled task's final hop to run before the last reference goes.
        for _ in 0 ..< 40 {
            if weakModel == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(weakModel == nil, "the window's DocumentModel outlived its window")
    }
}

// MARK: - Harness

/// One temporary workbook, one live ``DocumentModel``, and an external writer.
@MainActor
final class Harness {
    let url: URL
    let directory: URL
    let app: AppModel
    let model: DocumentModel

    static func makeStore() throws -> SheetStore {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return try SheetStore(
            mode: .app,
            configuration: SheetStore.Configuration(applicationSupport: support, denyList: .empty)
        )
    }

    init(
        name: String = "budget.xlsx",
        autoRefresh: Bool = true,
        seed: Double = 1,
        store: SheetStore? = nil,
        workbook seeded: Workbook? = nil
    ) async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)

        let workbook = try seeded ?? Harness.seedWorkbook(seed)
        var tracker = WorkbookEditTracker()
        if let sheet = workbook.sheets.first { tracker.noteSheetReplaced(sheet) }
        try XLSXWriter.data(for: workbook, edits: tracker).write(to: url)

        UserDefaults.standard.set(autoRefresh, forKey: "OSFlagAutoRefresh")
        app = AppModel(store: try store ?? Harness.makeStore())
        model = try await app.openDocument(at: url)
    }

    static func seedWorkbook(_ seed: Double) throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Item"), .text("Q1"), .text("Q2")],
                [.text("Salaries"), .number(100 + seed), .number(120 + seed)],
                [.text("Travel"), .number(10 + seed), .number(12 + seed)],
            ])
            .build()
    }

    func close() {
        app.closeDocument(model)
    }

    /// Edits the file the way another process would: build the new bytes, write them to a
    /// sibling, then `mv` over the original. Nothing in this path goes through `SheetStore`.
    func externalEdit(_ body: (inout Workbook) throws -> Void) async throws {
        var workbook = try await DocumentWorkbookReader.read(url)
        try body(&workbook)
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets { tracker.noteCellsChanged(in: sheet, formulasChanged: true) }
        let bytes = try XLSXWriter.data(for: workbook, edits: tracker)

        let staging = directory.appendingPathComponent("agent-\(UUID().uuidString).tmp")
        try bytes.write(to: staging)
        // `/bin/mv` rather than `FileManager.replaceItem`: an atomic rename from another process
        // is the case PLAN.md §6.1 calls out as the one a bare fd watcher misses.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/mv")
        process.arguments = [staging.path, url.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// Polls `condition` until it holds. Polling rather than awaiting a specific event because the
    /// thing under test is a filesystem watcher, and a test that asserts on event *order* would be
    /// asserting on the debounce.
    func waitFor(
        timeout: Duration = .seconds(8),
        _ condition: (DocumentModel) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition(model) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting; state=\(model.syncState) phase=\(model.syncPhase)")
    }

    /// Waits for the model to reach `state`, allowing for the one-hop trip to the session actor.
    func stateSettles(to state: DocumentSyncState) async -> Bool {
        for _ in 0 ..< 200 {
            if model.syncState == state { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
