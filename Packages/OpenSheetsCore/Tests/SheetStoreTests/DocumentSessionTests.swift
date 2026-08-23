import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// The five pieces wired together against a real filesystem — an integration test per state,
/// driven by real file operations, as the brief requires.
///
/// Uses ``FakeWorkbookReader``/``FakeWorkbookWriter`` rather than A1's and A2's real ones: the
/// behaviour under test is the sync engine, and a fake format keeps the assertions about
/// *"the app noticed and showed the right thing"* rather than about xlsx.
@Suite(.serialized) struct DocumentSessionTests {
    private func makeSession(
        _ scratch: TemporaryDirectory,
        contents: String = "#sheet 1 Data\n1|0,0,10\n1|0,1,20",
        autoRefresh: Bool = true,
        writer: FakeWorkbookWriter? = FakeWorkbookWriter(),
        snapshots: Bool = false
    ) throws -> (session: DocumentSession, url: URL, suppressor: SelfWriteSuppressor, reader: FakeWorkbookReader) {
        let url = scratch.file("book.fake", contents: contents)
        let reader = FakeWorkbookReader()
        let suppressor = SelfWriteSuppressor()
        let store = snapshots
            ? SnapshotStore(configuration: SnapshotStore.Configuration(
                root: scratch.url.appendingPathComponent("Snapshots")
            ))
            : nil
        let session = DocumentSession(
            url: url,
            workbook: try reader.readWorkbook(at: url),
            io: WorkbookIO(reader: reader, writer: writer),
            suppressor: suppressor,
            snapshots: store,
            options: DocumentSession.Options(
                autoRefresh: autoRefresh,
                watcher: .fast,
                snapshotsEnabled: snapshots
            )
        )
        return (session, url, suppressor, reader)
    }

    private func waitFor(
        _ session: DocumentSession,
        state: DocumentSyncState,
        timeout: TimeInterval = EventCollector.timeout
    ) async -> Bool {
        await waitUntil(timeout: timeout) { await session.state == state }
    }

    /// Polls a condition rather than a state.
    ///
    /// Waiting for a *state* is a trap when the document is already in it: `waitFor(.synced)`
    /// right after an external write returns instantly, before the reload has even started,
    /// and every assertion after it then reads stale data and passes for the wrong reason.
    private func waitUntil(
        timeout: TimeInterval = EventCollector.timeout,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - The headline flow

    /// **Claude Code edits the file, the app notices.** SYNCED → RELOADING → SYNCED, with the
    /// new content in memory and a diff describing it.
    @Test func externalEditRefreshesTheDocument() async throws {
        let scratch = TemporaryDirectory("external-edit")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }
        #expect(await session.state == .synced)

        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,10\\n1|0,1,99' > '\(url.path(percentEncoded: false))'") == 0)
        let refreshed = await waitUntil {
            await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 1)]?.value == .number(99)
        }
        #expect(refreshed, "the app never noticed the external edit")
        #expect(await session.state == .synced)
        let history = await session.history
        #expect(history.contains { $0.to == .reloading }, "the document never went through RELOADING")
    }

    /// With auto-refresh off the document goes `STALE` and waits for ⌘R.
    @Test func autoRefreshOffGoesStaleUntilRefreshed() async throws {
        let scratch = TemporaryDirectory("stale")
        let (session, url, _, _) = try makeSession(scratch, autoRefresh: false)
        try await session.start()
        defer { Task { await session.stop() } }

        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,77' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitFor(session, state: .stale), "auto-refresh is off, so the document should go STALE")
        #expect(await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(10))

        await session.refresh()
        #expect(await session.state == .synced)
        #expect(await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(77))
    }

    /// An edit plus an external change is a conflict, and none of the three resolutions loses
    /// anything the user did not choose to lose.
    @Test func conflictKeepsBothVersionsUntilTheUserChooses() async throws {
        let scratch = TemporaryDirectory("conflict")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(555)), at: CellRef(row: 0, column: 0))
        }
        #expect(await session.state == .dirty)

        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,888' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitFor(session, state: .conflict))
        #expect(
            await session.workbook.sheets[0].cells[CellRef(row: 0, column: 0)]?.value == .number(555),
            "the conflict discarded the user's edit"
        )

        await session.resolveConflict(.keepMine)
        #expect(await waitFor(session, state: .synced))
        #expect(bytes(of: url).map { String(decoding: $0, as: UTF8.self) }?.contains("555") == true)
    }

    /// `takeDisk` is the one path that discards, and it does what it says.
    @Test func takeDiskDiscardsTheLocalEdit() async throws {
        let scratch = TemporaryDirectory("take-disk")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(555)), at: CellRef(row: 0, column: 0))
        }
        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,888' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitFor(session, state: .conflict))

        await session.resolveConflict(.takeDisk)
        #expect(await waitFor(session, state: .synced))
        #expect(await session.workbook.sheets[0].cells[CellRef(row: 0, column: 0)]?.value == .number(888))
        #expect(await !session.hasUnsavedEdits)
    }

    /// **Our own save produces no refresh.** The end-to-end version of the suppression test.
    @Test func ourOwnSaveDoesNotRefresh() async throws {
        let scratch = TemporaryDirectory("self-save")
        let (session, _, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        for round in 0 ..< 10 {
            await session.edit { workbook in
                try? workbook.sheets[0].cells.setCell(
                    Cell(value: .number(Double(round))),
                    at: CellRef(row: 0, column: 0)
                )
            }
            await session.save()
            #expect(await session.state == .synced, "save \(round) did not settle")
        }

        try? await Task.sleep(for: .milliseconds(400))
        #expect(await session.state == .synced, "the session refresh-looped after saving")
        let reloads = await session.history.count { $0.to == .reloading }
        #expect(reloads == 0, "\(reloads) reloads were triggered by our own saves")
    }

    // MARK: - The blocking states, driven by real file operations

    /// `MISSING`, and Save As out of it.
    @Test func deletingTheFileEntersMissingAndSaveAsRecovers() async throws {
        let scratch = TemporaryDirectory("missing")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        try FileManager.default.removeItem(at: url)
        #expect(await waitFor(session, state: .missing))
        #expect(await session.workbook.sheets.count == 1, "the document must still be in memory")

        let rescue = scratch.url.appendingPathComponent("rescued.fake")
        _ = try await session.saveAs(to: rescue)
        #expect(await session.state == .synced)
        #expect(bytes(of: rescue) != nil)
    }

    /// `LOCKED` — `chflags uchg`, which is Finder's "Locked" checkbox.
    @Test func lockingTheFileEntersLockedAndSavingIsRefused() async throws {
        let scratch = TemporaryDirectory("locked-session")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        let path = url.path(percentEncoded: false)
        #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(path, 0) }
        #expect(await waitFor(session, state: .locked))

        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(1)), at: CellRef(row: 5, column: 5))
        }
        await session.save()
        #expect(await session.state == .locked, "a save was attempted on a locked file")

        _ = chflags(path, 0)
        #expect(await waitFor(session, state: .dirty), "unlocking with edits pending should return to DIRTY")
    }

    /// `READ_ONLY` from the filesystem side.
    @Test func chmodEntersReadOnly() async throws {
        let scratch = TemporaryDirectory("readonly-session")
        let (session, url, _, _) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        let path = url.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        #expect(await waitFor(session, state: .readOnly))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        #expect(await waitFor(session, state: .synced))
    }

    /// `READ_ONLY` from the workbook's side: no writer at all. PLAN.md §5.2 — refusing to save
    /// beats corrupting.
    @Test func aFormatWeCannotWriteOpensReadOnly() async throws {
        let scratch = TemporaryDirectory("no-writer")
        let (session, _, _, _) = try makeSession(scratch, writer: nil)
        try await session.start()
        defer { Task { await session.stop() } }

        #expect(await session.state == .readOnly)
        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(1)), at: CellRef(row: 1, column: 1))
        }
        await session.save()
        #expect(await session.state == .readOnly)
    }

    /// `UNREADABLE`, and the recovery when the file becomes readable again.
    @Test func corruptFileEntersUnreadableAndRecovers() async throws {
        let scratch = TemporaryDirectory("unreadable")
        let (session, url, _, reader) = try makeSession(scratch)
        try await session.start()
        defer { Task { await session.stop() } }

        reader.failure.error = .xmlMalformed(part: "sheet1.xml", line: 4, detail: "unclosed element")
        #expect(Shell.run("printf 'garbage' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitFor(session, state: .unreadable), "a file the reader rejects should enter UNREADABLE")

        reader.failure.error = nil
        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,42' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitUntil {
            await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(42)
        })
        #expect(await session.state == .synced)
    }

    // MARK: - Snapshots

    /// PLAN.md §5.5: a snapshot before **every** external refresh and **every** one of our own
    /// saves. The state machine emits the effect, so this is structural rather than a rule
    /// somebody has to remember at each call site.
    @Test func snapshotsAreTakenBeforeEveryRefreshAndEverySave() async throws {
        let scratch = TemporaryDirectory("session-snapshots")
        let (session, url, _, _) = try makeSession(scratch, snapshots: true)
        try await session.start()
        defer { Task { await session.stop() } }

        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(1)), at: CellRef(row: 3, column: 0))
        }
        await session.save()
        #expect(await waitFor(session, state: .synced))
        let afterSave = try await session.snapshotHistory()
        #expect(afterSave.contains { $0.reason == .preSave }, "no snapshot before the save")

        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,7' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitUntil {
            await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(7)
        })
        let afterRefresh = try await session.snapshotHistory()
        #expect(afterRefresh.contains { $0.reason == .preRefresh }, "no snapshot before the refresh")
    }

    /// Restoring from the session puts the bytes back, pulls them into memory, and does not
    /// leave the document in a refresh loop.
    @Test func restoringThroughTheSessionRecoversTheFile() async throws {
        let scratch = TemporaryDirectory("session-restore")
        let (session, url, _, _) = try makeSession(scratch, snapshots: true)
        try await session.start()
        defer { Task { await session.stop() } }

        await session.edit { workbook in
            try? workbook.sheets[0].cells.setCell(Cell(value: .number(1)), at: CellRef(row: 4, column: 0))
        }
        await session.save()
        #expect(await waitFor(session, state: .synced))

        let snapshot = try #require(try await session.snapshotHistory().first { $0.reason == .preSave })
        #expect(Shell.run("printf '#sheet 1 Data\\n1|0,0,-1' > '\(url.path(percentEncoded: false))'") == 0)
        #expect(await waitUntil {
            await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(-1)
        })

        _ = try await session.restore(snapshot.id)
        #expect(await session.state == .synced)
        #expect(await session.workbook.sheets.first?.cells[CellRef(row: 0, column: 0)]?.value == .number(10))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await session.state == .synced, "the restore left the document refreshing")
    }

    // MARK: - The facade

    /// `SheetStore.openDocument` checks the grant **before** it reads the file, so a denial
    /// cannot be used to probe whether a path exists.
    @Test func openDocumentEnforcesTheGrantBeforeReading() async throws {
        let scratch = TemporaryDirectory("facade")
        let store = try SheetStore(
            mode: .app,
            configuration: SheetStore.Configuration(
                applicationSupport: scratch.url.appendingPathComponent("Support"),
                denyList: .standard
            )
        )
        let workspace = scratch.directory("work")
        let inside = workspace.appendingPathComponent("book.fake")
        try Data("#sheet 1 Data\n1|0,0,5".utf8).write(to: inside)
        let outside = scratch.file("outside.fake", contents: "#sheet 1 Data")
        let io = WorkbookIO(reader: FakeWorkbookReader(), writer: FakeWorkbookWriter())

        do {
            _ = try await store.openDocument(at: outside, io: io)
            Issue.record("a file outside every grant was opened")
        } catch {
            #expect(error.code == "grant.outsideWorkspace")
        }
        do {
            _ = try await store.openDocument(at: workspace.appendingPathComponent("does-not-exist.fake"), io: io)
            Issue.record("a nonexistent file outside every grant was opened")
        } catch {
            #expect(error.code == "grant.outsideWorkspace", "the denial must not depend on whether the file exists")
        }

        try store.grantWorkspace(UserGrantAuthorization(unchecked: workspace))
        let session = try await store.openDocument(at: inside, io: io)
        #expect(await session.state == .synced)
        await session.stop()

        #expect(try store.database.recentFiles().contains { $0.path == inside.path(percentEncoded: false) })
    }

    /// The MCP-mode store cannot create grants, so the boundary holds in the process that
    /// inherits the user's full file access.
    @Test func mcpModeStoreCannotWidenAGrant() throws {
        let scratch = TemporaryDirectory("facade-mcp")
        let store = try SheetStore(
            mode: .mcpServer,
            configuration: SheetStore.Configuration(applicationSupport: scratch.url.appendingPathComponent("Support"))
        )
        #expect(throws: SheetError.self) {
            try store.grantWorkspace(UserGrantAuthorization(unchecked: scratch.directory("work")))
        }
    }
}
