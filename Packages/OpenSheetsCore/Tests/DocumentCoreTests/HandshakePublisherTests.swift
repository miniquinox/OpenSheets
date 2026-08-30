import DocumentCore
import Foundation
import SheetMCP
import SheetModel
import SheetStore
import Testing
import TestSupport

/// What the app tells the MCP server about the documents it has open.
///
/// # Why every assertion goes through the server's own reader
///
/// The two halves of the handshake are two processes that never speak — they agree on a directory,
/// a file name and six JSON keys, and nothing but a passing test says they still do. So none of
/// these tests inspects the bytes the publisher wrote. They hand the file to
/// ``SheetMCP/AppHandshake/presence(for:)``, which is the code that will actually read it in
/// `opensheets-mcp`, and assert on what *it* says. A key renamed on either side, a hash spelled
/// differently, a timestamp in milliseconds: all of them fail here rather than in a live session.
///
/// Nothing here opens a window or a real store. The publisher takes its readings from an injected
/// closure for exactly that reason.
@Suite("Publishing what the app has open")
@MainActor
struct HandshakePublisherTests {
    // MARK: - The round trip

    /// The claim the whole feature rests on: `get_selection` can read what the app wrote.
    ///
    /// This is also the guard on two duplications the frozen protocol forced —
    /// ``SheetMCP/AppPresence`` has no public initialiser so the payload is rendered app-side, and
    /// `AppHandshake.key(_:)` is internal so the file name is derived app-side. Both are invisible
    /// to the compiler and both fail this test the moment they drift.
    @Test func aPublishedRecordIsWhatTheServerReadsBack() throws {
        let directory = try Temp.directory()
        let file = URL(fileURLWithPath: "/tmp/opensheets-handshake/budget.xlsx")
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: {
                [HandshakeDocumentSnapshot(
                    url: file, sheetName: "Q4", selection: "B2:B41", activeCell: "B2"
                )]
            }
        )

        #expect(publisher.publishNow() == 1)

        let server = AppHandshake(applicationSupport: directory)
        let presence = try #require(server.presence(for: file), "the server reads a fresh record")
        #expect(presence.sheetName == "Q4")
        #expect(presence.selection == "B2:B41")
        #expect(presence.activeCell == "B2")
        #expect(presence.path == file.path(percentEncoded: false))
        #expect(presence.processID == Int(getpid()))
    }

    /// Two spellings of one path are one document — the same rule
    /// ``DocumentCore/AppModel/documentKey(for:)`` enforces everywhere else. The server resolves
    /// symlinks when it hashes, so a publisher that wrote the raw path would file the record under
    /// a name the server never looks for.
    @Test func aRecordIsFiledUnderTheCanonicalPathTheServerWillAskFor() throws {
        let directory = try Temp.directory()
        let workspace = try Temp.directory()
        let file = workspace.appendingPathComponent("budget.xlsx")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())
        // `/var` is a symlink to `/private/var` on macOS, which is what makes the temporary
        // directory a real test of this rather than a spelling exercise.
        let asAsked = URL(fileURLWithPath: file.path(percentEncoded: false))
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: {
                [HandshakeDocumentSnapshot(
                    url: asAsked, sheetName: "Sheet1", selection: "A1", activeCell: "A1"
                )]
            }
        )
        publisher.publishNow()

        let resolved = URL(fileURLWithPath: asAsked.resolvingSymlinksInPath().path(percentEncoded: false))
        #expect(AppHandshake(applicationSupport: directory).presence(for: resolved) != nil)
    }

    // MARK: - Withdrawal

    /// Closing a tab has to take the record with it. Letting it age out would leave ninety seconds
    /// in which the server confidently reports a selection in a file the user has shut.
    @Test func withdrawingLeavesNothingForTheServerToRead() throws {
        let directory = try Temp.directory()
        let file = URL(fileURLWithPath: "/tmp/opensheets-handshake/budget.xlsx")
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: {
                [HandshakeDocumentSnapshot(url: file, sheetName: "Q4", selection: "A1", activeCell: "A1")]
            }
        )
        publisher.publishNow()
        #expect(AppHandshake(applicationSupport: directory).presence(for: file) != nil)

        publisher.withdraw(file)

        #expect(
            AppHandshake(applicationSupport: directory).presence(for: file) == nil,
            "the record is gone, not merely old"
        )
    }

    /// Withdrawing something that was never published is silence, not an error. A tab can be closed
    /// while it is still loading, and it never had a record.
    @Test func withdrawingSomethingNeverPublishedIsHarmless() throws {
        let directory = try Temp.directory()
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: { [] }
        )
        publisher.withdraw(URL(fileURLWithPath: "/tmp/opensheets-handshake/never-opened.xlsx"))
        #expect(publisher.publishNow() == 0)
    }

    // MARK: - What is never published

    /// **A tab that is still loading, or that failed to open, publishes nothing.**
    ///
    /// Through a real ``DocumentCore/TabsModel`` rather than a hand-made phase, because the rule
    /// lives in `HandshakeDocumentSnapshot.init?(tab:)` and the thing worth proving is that the tab
    /// strip's own phases drive it. A record for a loading tab would tell an agent the app is
    /// sitting on a selection in a file it cannot yet show; a record for a failed one would claim a
    /// file is open that demonstrably is not.
    @Test func aTabThatIsLoadingOrFailedPublishesNothing() async throws {
        let directory = try Temp.directory()
        let spy = try TabSpy()
        let tabs = spy.makeTabs()
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: { tabs.tabs.compactMap(HandshakeDocumentSnapshot.init(tab:)) }
        )

        // Loading: the tab is inserted before the open is awaited, so it exists in `.loading` for
        // as long as the spy parks it.
        spy.holdsOpens = true
        let loading = Task { await tabs.open(Self.budget, consent: .userSelectedInPanel) }
        while tabs.tabs.isEmpty { await Task.yield() }
        #expect(tabs.tabs.count == 1)
        #expect(publisher.publishNow() == 0, "a loading tab has no selection to report")

        spy.holdsOpens = false
        spy.release()
        await loading.value
        #expect(publisher.publishNow() == 1, "and it publishes the moment it is ready")

        // Failed: a file whose grant is gone. The tab stays, carrying the reason.
        spy.refusing = ["missing.xlsx"]
        await tabs.open(Self.missing, consent: .userSelectedInPanel)
        #expect(tabs.tabs.count == 2)
        #expect(publisher.publishNow() == 1, "still only the ready one")
        #expect(AppHandshake(applicationSupport: directory).presence(for: Self.missing) == nil)
    }

    // MARK: - Degradation

    /// A record whose process is gone is not believed, however recent it is.
    ///
    /// This is the force-quit and the crash: nothing ran to withdraw the record, so age alone would
    /// have the server reporting a selection in a window that is not on screen. The pid check is
    /// the half of ``SheetMCP/AppPresence/isFresh(now:tolerance:)`` that catches it, and the
    /// publisher takes the pid as a parameter so it can be exercised.
    @Test func aRecordFromAProcessThatIsGoneIsNotBelieved() throws {
        let directory = try Temp.directory()
        let file = URL(fileURLWithPath: "/tmp/opensheets-handshake/budget.xlsx")
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: {
                [HandshakeDocumentSnapshot(url: file, sheetName: "Q4", selection: "A1", activeCell: "A1")]
            },
            // Above macOS's `PID_MAX` of 99999, so it can never name a live process.
            processID: 999_999
        )
        publisher.publishNow()

        #expect(AppHandshake(applicationSupport: directory).presence(for: file) == nil)
    }

    /// A record older than the ninety-second tolerance is not believed either — the case where the
    /// app is wedged rather than gone, so the pid is still live and only the clock says so.
    @Test func aRecordOlderThanTheToleranceIsNotBelieved() throws {
        let directory = try Temp.directory()
        let file = URL(fileURLWithPath: "/tmp/opensheets-handshake/budget.xlsx")
        let publisher = HandshakePublisher(
            handshake: AppHandshake(applicationSupport: directory),
            documents: {
                [HandshakeDocumentSnapshot(url: file, sheetName: "Q4", selection: "A1", activeCell: "A1")]
            },
            now: { Date().addingTimeInterval(-120) }
        )
        publisher.publishNow()

        #expect(AppHandshake(applicationSupport: directory).presence(for: file) == nil)
        #expect(
            AppHandshake(applicationSupport: directory, now: { Date().addingTimeInterval(-120) })
                .presence(for: file) != nil,
            "and it is the age that did it, not the write"
        )
    }

    // MARK: - The reading

    /// The snapshot says what the app has open, in the one spelling both ends can parse. `selection`
    /// is the active rectangle in A1 and `activeCell` the plain A1 cell inside it, so everything
    /// `get_selection` reports can be handed straight back to `read_range`.
    @Test func aSnapshotOfALiveDocumentCarriesItsSheetSelectionAndActiveCell() throws {
        let document = try TabSpy().makeDocument(at: Self.budget)
        document.selection.select(try #require(CellRange(a1: "B2:B4")), active: CellRef(a1: "B2"))

        let snapshot = HandshakeDocumentSnapshot(document: document)

        #expect(snapshot.url == Self.budget)
        #expect(snapshot.sheetName == "Q4")
        #expect(snapshot.selection == "B2:B4")
        #expect(snapshot.activeCell == "B2")
    }

    /// **A block selection is published as a rectangle, not as its size.**
    ///
    /// ``SelectionStats/rangeLabel`` renders a multi-row, multi-column selection as `41R × 3C` —
    /// right for the status bar a person reads, useless to an agent, which cannot turn a shape
    /// back into an address. This is the case where the two spellings diverge, so it is the case
    /// worth asserting: the single-column selection above passes either way.
    @Test func aBlockSelectionIsPublishedAsARangeAnAgentCanRead() throws {
        let document = try TabSpy().makeDocument(at: Self.budget)
        let block = try #require(CellRange(a1: "B2:D42"))
        document.selection.select(block, active: CellRef(a1: "B2"))

        let snapshot = HandshakeDocumentSnapshot(document: document)

        #expect(snapshot.selection == "B2:D42")
        #expect(snapshot.selection != SelectionStatistics.label(for: document.selection))
        #expect(CellRange(a1: snapshot.selection) != nil, "the published selection must re-parse")
    }

    // MARK: - The kill switch

    /// `OSFlagHandshake` off means **neither half exists** — no timer, no directory watch, no
    /// records. Off has to remove the cost, not hide the feature.
    ///
    /// Asserted through ``DocumentCore/AppModel/handshakeForThisInstance`` rather than by writing
    /// the default, because `UserDefaults` is process-wide: a suite that wrote the flag could have
    /// another write it back underneath, and this assertion would fail somewhere else entirely.
    /// The flag is what the shipping app reads; this is the same decision without the race.
    @Test func theKillSwitchWithholdsBothHalves() throws {
        let app = AppModel(store: try Temp.store())
        app.handshakeForThisInstance = false
        let tabs = try TabSpy().makeTabs()

        app.startHandshake(tabs: tabs, openFile: { _ in })

        #expect(app.handshakePublisher == nil)
        #expect(app.handshakeRevealConsumer == nil)
        #expect(
            !FileManager.default.fileExists(atPath: app.handshakeDirectory.path(percentEncoded: false)),
            "not even the directory"
        )
    }

    /// And on, both exist — otherwise the test above would pass with the feature deleted.
    @Test func theKillSwitchOnStartsBothHalves() throws {
        let app = AppModel(store: try Temp.store())
        app.handshakeForThisInstance = true
        let tabs = try TabSpy().makeTabs()

        app.startHandshake(tabs: tabs, openFile: { _ in })
        defer { app.stopHandshake() }

        #expect(app.handshakePublisher != nil)
        #expect(app.handshakeRevealConsumer != nil)
        #expect(
            app.handshakeRevealConsumer?.directory == app.handshakeDirectory,
            "and they are pointed at the store's own application support, not at ~/Library"
        )
    }

    /// Starting twice must not leave two publishers writing the same records on two timers. The
    /// workspace window rebuilds its body more than once.
    @Test func startingTwiceKeepsTheFirstPair() throws {
        let app = AppModel(store: try Temp.store())
        let tabs = try TabSpy().makeTabs()

        app.startHandshake(tabs: tabs, openFile: { _ in })
        defer { app.stopHandshake() }
        let publisher = app.handshakePublisher
        let consumer = app.handshakeRevealConsumer

        app.startHandshake(tabs: tabs, openFile: { _ in })

        #expect(app.handshakePublisher === publisher)
        #expect(app.handshakeRevealConsumer === consumer)
    }

    // MARK: - Fixtures

    private static let budget = URL(fileURLWithPath: "/tmp/opensheets-handshake/budget.xlsx")
    private static let missing = URL(fileURLWithPath: "/tmp/opensheets-handshake/missing.xlsx")
}

// MARK: - Support

/// Temporary directories and stores, so nothing here touches `~/Library`.
enum Temp {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-handshake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func store() throws -> SheetStore {
        try SheetStore(
            mode: .app,
            configuration: SheetStore.Configuration(applicationSupport: try directory(), denyList: .empty)
        )
    }
}

/// A tab strip whose opens are fake but whose documents are real.
///
/// The same shape as `TabsModelTests.Spy` and for the same reason: the phases are what these tests
/// are about, and standing up a store and parsing XLSX bytes to reach them would be slower, flakier
/// and no more convincing. The session is never started, so there is no watcher and no file
/// descriptor — but the document a tab carries is the type the window will get.
@MainActor
final class TabSpy {
    /// Last path components that refuse to open, standing in for a revoked grant or a missing file.
    var refusing: Set<String> = []
    /// While true, every open parks until ``release()``.
    var holdsOpens = false

    private let workbook: Workbook
    private let reader = DocumentWorkbookReader()
    private var parked: [CheckedContinuation<Void, Never>] = []

    init() throws {
        workbook = try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Item"), .text("Q1"), .text("Q2")],
                [.text("Salaries"), .number(101), .number(121)],
                [.text("Travel"), .number(11), .number(13)],
            ])
            .build()
    }

    func makeTabs() -> TabsModel {
        TabsModel(
            // Written out in full because it has to be — see `TabsModel.init(open:close:persist:)`.
            open: { [self] (url: URL, _: WorkspaceConsent) async throws(SheetError) -> DocumentModel in
                try await open(url)
            },
            close: { model in model.close() },
            persist: { _ in }
        )
    }

    func release() {
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }

    func makeDocument(at url: URL) -> DocumentModel {
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

    private func open(_ url: URL) async throws(SheetError) -> DocumentModel {
        if holdsOpens {
            await withCheckedContinuation { parked.append($0) }
        }
        guard !refusing.contains(url.lastPathComponent) else {
            throw SheetError.pathOutsideWorkspace(path: url.path(percentEncoded: false))
        }
        return makeDocument(at: url)
    }
}
