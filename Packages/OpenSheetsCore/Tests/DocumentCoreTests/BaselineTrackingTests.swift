import DocumentCore
import Foundation
import SheetFormat
import SheetModel
import SheetStore
import TestSupport
import Testing

/// PLAN.md §1.3 — the baseline a document tracks changes against, and the checkpoint that moves
/// it.
///
/// # What these are really checking
///
/// The feature is four numbers on a chip, and the four numbers are the easy part. What is hard,
/// and what these tests are mostly about, is that the numbers are computed **off the main
/// actor** while the workbook underneath them keeps moving: an agent writes the file, the user
/// types, a checkpoint lands, and each of those makes some pass that is already running answer
/// the wrong question. A stale answer that arrives after a newer one is not a slow chip, it is a
/// chip that intermittently shows the state before the last edit — which is the kind of bug that
/// is reported as "the highlights are flaky" and never reproduced.
///
/// So the assertions here are about *ordering and thrift* as much as about arithmetic: how many
/// passes ran, which one landed, and what happens when the baseline moves out from under one.
@Suite(.serialized)
@MainActor
struct BaselineTrackingTests {
    // MARK: - The default baseline

    /// A document opens tracking against itself, so the chip starts silent.
    @Test func aFreshDocumentTracksAgainstWhatItOpenedWith() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }

        #expect(opened.model.baselineSource == .asOpened)
        #expect(opened.model.baselineDiff == .empty)
        #expect(opened.model.baselineCounts == .zero)
        #expect(opened.model.baselineCounts.isEmpty)
        // Nothing has changed, so nothing has been compared. The empty answer is known by
        // construction rather than computed — see `adoptCurrentWorkbookAsBaseline`.
        #expect(opened.model.baselineComputeCount == 0)
    }

    /// The counts a chip shows, against a hand-counted edit: one cell changed, one added, one
    /// taken away.
    @Test func anExternalEditIsCountedAsAddedModifiedAndRemoved() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }
        let sheetID = opened.model.workbook.sheets[0].id

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(129.6), at: BaselineWorkspace.ref("B2"))
                try sheet.cells.setCell(.text("new"), at: BaselineWorkspace.ref("D3"))
                _ = sheet.cells.removeCell(at: BaselineWorkspace.ref("C4"))
            }
        }
        try await opened.settle { $0.baselineCounts != .zero }

        #expect(opened.model.baselineCounts == BaselineCounts(added: 1, modified: 1, removed: 1))
        #expect(opened.model.baselineSource == .asOpened, "a refresh must not move the baseline")
        #expect(opened.model.lastRefreshAt != nil, "§1.5's accent dot has nothing to go on")
    }

    /// Two agent writes in a row **accumulate**. A refresh is not a checkpoint — that is the
    /// point of having a checkpoint.
    @Test func successiveRefreshesAccumulateAgainstTheSameBaseline() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }
        let sheetID = opened.model.workbook.sheets[0].id

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(1), at: BaselineWorkspace.ref("B2"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 1 }

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(2), at: BaselineWorkspace.ref("C3"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 2 }
        #expect(opened.model.baselineCounts == BaselineCounts(modified: 2))
    }

    // MARK: - Debounce and thrift

    /// Ten edits in one burst are **one** pass, not ten.
    ///
    /// The claim is not "it feels fast": it is that the number of comparisons over the workbook
    /// is bounded by how long the user pauses, not by how fast they type. That is only checkable
    /// by counting, which is what `baselineComputeCount` is for.
    @Test func aBurstOfEditsIsDebouncedIntoOnePass() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open(autoRefresh: false)
        defer { opened.close() }

        let refs = ["B1", "A2", "B2", "C2", "A3", "B3", "C3", "A4", "B4", "C4"]
        for (index, a1) in refs.enumerated() {
            _ = opened.model.commitEdit(at: BaselineWorkspace.ref(a1), text: "\(900 + index)")
        }
        try await opened.settle { $0.baselineCounts.modified == refs.count }

        #expect(opened.model.baselineComputeCount < refs.count, "the debounce is not debouncing")
        #expect(opened.model.baselineComputeCount >= 1)
    }

    /// Edits spread over several debounce windows keep the answer honest at the end.
    ///
    /// This is the interleaved half of the staleness guard: each pass starts against a workbook
    /// the next edit is about to replace, so any pass that landed out of order would leave the
    /// chip short. The guard itself is structural — a generation counter compared on the way
    /// back — and this is what proves it holds while the workbook is genuinely moving.
    @Test func interleavedEditsLeaveTheChipShowingTheLastOne() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open(autoRefresh: false)
        defer { opened.close() }

        let refs = ["B1", "A2", "B2", "C2", "A3", "B3"]
        for (index, a1) in refs.enumerated() {
            _ = opened.model.commitEdit(at: BaselineWorkspace.ref(a1), text: "\(700 + index)")
            try await Task.sleep(for: .milliseconds(620))
        }
        try await opened.settle { $0.baselineCounts.modified == refs.count }

        #expect(opened.model.baselineCounts == BaselineCounts(modified: refs.count))
        let sheet = try #require(opened.model.activeSheet)
        #expect(sheet.cells[BaselineWorkspace.ref("B3")]?.value == .number(705))
    }

    /// A checkpoint set while a pass is still pending wins.
    ///
    /// The deterministic half of the staleness guard, and the one that would fail loudest if the
    /// baseline generation were not checked: the pending pass was scheduled against the *old*
    /// baseline, and landing it would repaint the grid with changes the user just declared to be
    /// the new normal.
    @Test func aCheckpointSupersedesTheRecomputeItInterrupted() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open(autoRefresh: false)
        defer { opened.close() }

        _ = opened.model.commitEdit(at: BaselineWorkspace.ref("B2"), text: "4242")
        // Inside the 500 ms debounce, so a pass is scheduled and has not run.
        await opened.model.setCheckpoint()
        #expect(opened.model.baselineDiff == .empty)

        // Well past the debounce the interrupted pass would have landed by now.
        try await Task.sleep(for: .milliseconds(900))
        #expect(opened.model.baselineDiff == .empty, "a superseded pass overwrote a newer answer")
        #expect(opened.model.baselineSource == .checkpoint)
    }

    // MARK: - Checkpoints

    /// ⇧⌘K: the snapshot, the preference and the cleared chip, in that order.
    @Test func settingACheckpointClearsTheChipAndLeavesASnapshotBehind() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }
        let sheetID = opened.model.workbook.sheets[0].id

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(129.6), at: BaselineWorkspace.ref("B2"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 1 }

        await opened.model.setCheckpoint()
        #expect(opened.model.baselineSource == .checkpoint)
        #expect(opened.model.baselineDiff == .empty)
        #expect(opened.model.isCheckpointAvailable)

        let snapshots = await opened.model.snapshots()
        let checkpoint = try #require(snapshots.first { $0.reason == .checkpoint })
        #expect(workspace.storedCheckpointID() == checkpoint.id.rawValue)
    }

    /// The checkpoint survives a relaunch — which is the only reason it is backed by bytes at
    /// all. A second `AppModel` over the same store is exactly what the next launch is.
    @Test func aCheckpointSurvivesIntoTheNextSession() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let sheetID: SheetID

        do {
            let first = try await workspace.open()
            defer { first.close() }
            sheetID = first.model.workbook.sheets[0].id
            await first.model.setCheckpoint()
            #expect(first.model.baselineSource == .checkpoint)
        }

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(77), at: BaselineWorkspace.ref("C3"))
                try sheet.cells.setCell(.text("agent"), at: BaselineWorkspace.ref("D2"))
            }
        }

        let second = try await workspace.open()
        defer { second.close() }
        try await second.settle { $0.baselineSource == .checkpoint }
        try await second.settle { $0.baselineCounts != .zero }
        #expect(second.model.baselineCounts == BaselineCounts(added: 1, modified: 1))
    }

    /// …**including in a workbook full of formulas**, which is the case that lost one.
    ///
    /// The restore of a persisted checkpoint is asynchronous — a SQLite read, a gunzip and a
    /// workbook parse — and it used to be discarded if anything had moved the baseline while it
    /// was in flight. In a file with a formula whose cached value is missing, something always
    /// has: recalculation on open lands, the as-opened baseline moves onto the corrected values,
    /// and the checkpoint arriving a moment later was thrown away as stale. It was not stale, and
    /// the user's checkpoint silently became *Since opened* on every relaunch. The fix counts the
    /// user's own baseline *choices* rather than every baseline move; this test is the difference
    /// between the two, so `lastOpenRecalculation` is asserted as well — without a recalculation
    /// having actually run, the test would pass without exercising anything.
    @Test func aCheckpointSurvivesTheRecalculationOnOpen() async throws {
        let workspace = try BaselineWorkspace(seed: BaselineWorkspace.seedWithAnUncachedFormula())
        defer { workspace.remove() }

        do {
            let first = try await workspace.open()
            defer { first.close() }
            await first.model.setCheckpoint()
            #expect(first.model.baselineSource == .checkpoint)
        }
        #expect(workspace.storedCheckpointID() != nil)

        let second = try await workspace.open()
        defer { second.close() }
        try await second.settle { $0.lastOpenRecalculation != nil }
        #expect(second.model.lastOpenRecalculation?.changedAnything == true, "no recalculation ran")
        try await second.settle { $0.baselineSource == .checkpoint }
        #expect(second.model.baselineSource == .checkpoint)
    }

    /// An evicted checkpoint falls back to *as opened*, quietly.
    ///
    /// Twenty snapshots per file is a real budget, so a checkpoint left alone through a busy
    /// week is a checkpoint that may not be there any more. Honest fallback beats a stale
    /// baseline, and neither is an error the user caused — so `lastError` stays clean.
    @Test func anEvictedCheckpointFallsBackToAsOpened() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }

        do {
            let first = try await workspace.open()
            defer { first.close() }
            await first.model.setCheckpoint()
        }
        #expect(workspace.storedCheckpointID() != nil)
        await workspace.store.snapshots.forget(workspace.url)

        let second = try await workspace.open()
        defer { second.close() }
        // The dead reference is cleared on the way past, which is the observable half of the
        // fallback: without it every launch would decompress nothing, forever.
        try await second.settle { _ in workspace.storedCheckpointID() == nil }
        #expect(second.model.baselineSource == .asOpened)
        #expect(!second.model.isCheckpointAvailable)
        #expect(second.model.lastError == nil)
    }

    /// Choosing a source that cannot produce a baseline leaves the one in hand alone. A model
    /// that claimed a baseline it does not have would paint the grid from nothing.
    @Test func choosingAnUnavailableSourceChangesNothing() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }

        await opened.model.setBaselineSource(.checkpoint)
        #expect(opened.model.baselineSource == .asOpened)
        #expect(!opened.model.isCheckpointAvailable)

        await opened.model.setBaselineSource(.gitHEAD)
        #expect(opened.model.baselineSource == .asOpened)
        #expect(!opened.model.isGitBaselineAvailable, "no provider is installed in this wave")
    }

    /// Switching back to *as opened* really does go back to the value the file had at open —
    /// not to the checkpoint under a different name.
    @Test func switchingBackToAsOpenedRestoresTheOpeningValue() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }
        let sheetID = opened.model.workbook.sheets[0].id

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(5), at: BaselineWorkspace.ref("B2"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 1 }
        await opened.model.setCheckpoint()
        #expect(opened.model.baselineDiff == .empty)

        await opened.model.setBaselineSource(.asOpened)
        try await opened.settle { $0.baselineCounts.modified == 1 }
        #expect(opened.model.baselineSource == .asOpened)
    }

    // MARK: - The flag

    /// `OSFlagChangeTracking` off removes the **cost**, not just the controls.
    ///
    /// Injected on this `AppModel` rather than written to `UserDefaults`, which is process-wide:
    /// a suite that set the flag while another suite's document was mid-recompute would turn
    /// this assertion into a flake that reads like a diffing bug. The same lesson
    /// `autoRefreshForNewDocuments` was built from.
    @Test func theFlagOffMeansNoWorkAtAll() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open(autoRefresh: false, changeTracking: false)
        defer { opened.close() }

        #expect(opened.model.baselineDiff == nil)
        for a1 in ["B2", "C2", "B3"] {
            _ = opened.model.commitEdit(at: BaselineWorkspace.ref(a1), text: "11")
        }
        try await Task.sleep(for: .milliseconds(900))

        #expect(opened.model.baselineDiff == nil, "a diff was computed with tracking switched off")
        #expect(opened.model.baselineComputeCount == 0)
        #expect(opened.model.baselineCounts == .zero)

        await opened.model.setCheckpoint()
        #expect(opened.model.baselineSource == .asOpened)
        let snapshots = await opened.model.snapshots()
        #expect(!snapshots.contains { $0.reason == .checkpoint }, "a no-op still took a snapshot")
        #expect(workspace.storedCheckpointID() == nil)
    }

    // MARK: - The chip's arithmetic

    /// Style-only differences are counted apart from real ones, and never folded into `~`.
    ///
    /// Pure arithmetic over a hand-built diff rather than a round trip through a file: the rule
    /// being checked is the split, and a test that had to reformat a cell in xlsx to reach it
    /// would be testing the writer.
    @Test func styleOnlyChangesAreCountedSeparately() {
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: SheetID(1),
                sheetName: "Q4",
                cellChanges: [
                    change("A1", kind: .added),
                    change("A2", kind: .valueChanged),
                    change("A3", kind: .formulaChanged),
                    change("A4", kind: .styleChanged),
                    change("A5", kind: .removed),
                ],
                addedCount: 1,
                removedCount: 1,
                changedCount: 3
            ),
        ])

        #expect(BaselineTracker.counts(for: diff) == BaselineCounts(
            added: 1, modified: 2, removed: 1, styleOnly: 1
        ))
    }

    /// Truncation is reported rather than hidden. A chip that says `12` when the differ gave up
    /// at five million comparisons is lying with a straight face.
    @Test func truncationIsCarriedIntoTheCounts() {
        let capped = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: SheetID(1),
                sheetName: "Q4",
                omittedCellChangeCount: 400,
                changedCount: 900
            ),
        ])
        #expect(BaselineTracker.counts(for: capped).isTruncated)

        let gaveUp = WorkbookDiff(sheetDiffs: [], wasTruncated: true)
        #expect(BaselineTracker.counts(for: gaveUp).isTruncated)

        #expect(BaselineTracker.counts(for: nil) == .zero)
    }

    /// A sheet that appeared wholesale is every one of its cells added. The differ reports it as
    /// a summary, and a chip that only read `sheetDiffs` would show `+0` beside a green grid.
    @Test func addedAndRemovedSheetsCountTheirCells() {
        let diff = WorkbookDiff(
            addedSheets: [SheetSummary(id: SheetID(2), name: "Q1", cellCount: 320)],
            removedSheets: [SheetSummary(id: SheetID(3), name: "Old", cellCount: 12)]
        )
        #expect(BaselineTracker.counts(for: diff) == BaselineCounts(added: 320, removed: 12))
    }

    // MARK: - The highlight switch

    /// One switch for the whole app, and it survives a relaunch.
    @Test func theHighlightSwitchMirrorsItsDefault() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "OSChangeHighlights") as? Bool
        defer {
            if let original {
                defaults.set(original, forKey: "OSChangeHighlights")
            } else {
                defaults.removeObject(forKey: "OSChangeHighlights")
            }
        }

        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }

        #expect(opened.model.isChangeHighlightingEnabled, "highlights are on by default")
        opened.model.isChangeHighlightingEnabled = false
        #expect(defaults.object(forKey: "OSChangeHighlights") as? Bool == false)

        let second = try await workspace.open()
        defer { second.close() }
        #expect(!second.model.isChangeHighlightingEnabled, "the switch did not survive")
    }

    private func change(_ a1: String, kind: CellChange.Kind) -> CellChange {
        CellChange(
            ref: BaselineWorkspace.ref(a1),
            before: kind == .added ? nil : .number(1),
            after: kind == .removed ? nil : .number(2),
            kind: kind
        )
    }
}

// MARK: - Harness

/// A temporary folder with one workbook in it, and a ``SheetStore`` that outlives any one
/// ``AppModel``.
///
/// The store being separate is the whole point: "does a checkpoint survive a relaunch" is
/// answered by opening a *second* `AppModel` over the *same* store, which is precisely what the
/// next launch of the app is. `CoreLoopTests.Harness` builds its store inside itself and opens
/// immediately, so it cannot express either that or "open with the flag off" — hence a second,
/// smaller harness rather than a change to a file this task does not own.
@MainActor
final class BaselineWorkspace {
    let directory: URL
    let support: URL
    let url: URL
    let store: SheetStore

    init(name: String = "budget.xlsx", seed: Workbook? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-baseline-\(UUID().uuidString)")
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-baseline-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)

        let workbook = try seed ?? BaselineWorkspace.seed()
        var tracker = WorkbookEditTracker()
        if let sheet = workbook.sheets.first { tracker.noteSheetReplaced(sheet) }
        try XLSXWriter.data(for: workbook, edits: tracker).write(to: url)

        store = try SheetStore(
            mode: .app,
            configuration: SheetStore.Configuration(applicationSupport: support, denyList: .empty)
        )
        try store.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: directory))
    }

    /// A fresh `AppModel` over the shared store, and the document it opens.
    func open(
        autoRefresh: Bool = true,
        changeTracking: Bool = true
    ) async throws -> OpenedBaselineDocument {
        let app = AppModel(store: store)
        app.autoRefreshForNewDocuments = autoRefresh
        app.changeTrackingForNewDocuments = changeTracking
        return OpenedBaselineDocument(app: app, model: try await app.openDocument(at: url))
    }

    /// PLAN.md §1.7's key, read straight out of the preference table.
    ///
    /// Spelled with `do`/`catch` rather than `try?` on purpose: `try?` over a function that
    /// already returns an optional flattens, and *"the read failed"* and *"there is no
    /// checkpoint"* are the two answers this predicate exists to tell apart. A test whose
    /// condition cannot distinguish them is a test that can pass without ever being true.
    func storedCheckpointID() -> String? {
        do {
            return try store.database.preference("checkpoint:" + AppModel.documentKey(for: url))
        } catch {
            return nil
        }
    }

    /// Edits the file the way another process would — build the bytes, then `mv` over the
    /// original. An in-process `Data.write` is a write the watcher sees through a path we
    /// control; an out-of-process atomic rename is what every real writer actually does.
    func externalEdit(_ body: (inout Workbook) throws -> Void) async throws {
        var workbook = try await DocumentWorkbookReader.read(url)
        try body(&workbook)
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets { tracker.noteCellsChanged(in: sheet, formulasChanged: true) }
        let bytes = try XLSXWriter.data(for: workbook, edits: tracker)

        let staging = directory.appendingPathComponent("agent-\(UUID().uuidString).tmp")
        try bytes.write(to: staging)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/mv")
        process.arguments = [staging.path, url.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: support)
    }

    /// Four rows, three columns, no formulas — small enough that a diff is exact and large
    /// enough that removing one cell is not mistaken for deleting a row.
    static func seed() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Item"), .text("Q1"), .text("Q2")],
                [.text("Salaries"), .number(101), .number(121)],
                [.text("Travel"), .number(11), .number(13)],
                [.text("Rent"), .number(20), .number(22)],
            ])
            .build()
    }

    /// The same four rows with a **total whose cached value is missing**, which is what every
    /// openpyxl and pandas write leaves behind — and the shape of file this whole product exists
    /// for. Opening it makes ``DocumentCore/OpenRecalculation`` run, which is the event
    /// ``aCheckpointSurvivesTheRecalculationOnOpen()`` needs to have happened.
    static func seedWithAnUncachedFormula() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Item"), .text("Q1"), .text("Q2")],
                [.text("Salaries"), .number(101), .number(121)],
                [.text("Travel"), .number(11), .number(13)],
                [.text("Rent"), .number(20), .number(22)],
            ])
            .formula("B5", "SUM(B2:B4)")
            .build()
    }

    /// A1 notation the tests can write inline. The refs here are all literals in this file, so a
    /// failure to parse one is a typo in a test rather than anything the product can reach.
    static func ref(_ a1: String) -> CellRef {
        CellRef(a1: a1) ?? CellRef(row: 0, column: 0)
    }
}

/// One `AppModel` and the document it opened.
@MainActor
struct OpenedBaselineDocument {
    let app: AppModel
    let model: DocumentModel

    func close() {
        app.closeDocument(model)
    }

    /// Polls until `condition` holds. Polling rather than awaiting an event because the things
    /// being waited on are a filesystem watcher and a debounce, and a test that asserted on
    /// their *timing* would be asserting on the debounce rather than on the answer.
    func settle(
        timeout: Duration = .seconds(10),
        _ condition: (DocumentModel) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition(model) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let diagnosis = "timed out; source=\(model.baselineSource) counts=\(model.baselineCounts) "
            + "passes=\(model.baselineComputeCount) sync=\(model.syncState)"
        Issue.record(Comment(rawValue: diagnosis))
    }
}
