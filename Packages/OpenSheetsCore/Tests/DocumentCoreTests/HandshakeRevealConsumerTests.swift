import DocumentCore
import Foundation
import SheetMCP
import SheetModel
import Testing
import TestSupport

/// What the app does with a `reveal_range` request an agent left in the handshake directory.
///
/// # A request is a suggestion, and this is the end that has to mean it
///
/// The file is written by whatever is on the other end of the MCP stream, which the threat model
/// assumes is hostile. So the interesting tests here are the refusals — a request that is too old,
/// one naming a folder the user has since revoked, one that is not JSON at all — and every one of
/// them asserts the same two things: **nothing happened, and the file is gone**. A request left
/// behind is one that gets reconsidered on every event for the rest of the session.
///
/// None of this stands up an app. The consumer takes its four effects as closures precisely so the
/// rules can be asserted with a temporary directory and nothing else.
@Suite("Consuming reveal requests")
@MainActor
struct HandshakeRevealConsumerTests {
    // MARK: - The happy paths

    /// A file that is not open is opened, through the app's own open funnel, and then revealed.
    @Test func aRequestForAFileThatIsNotOpenOpensItAndRevealsTheRange() async throws {
        let spy = try RevealSpy()
        let file = spy.granted.appendingPathComponent("budget.xlsx")
        try spy.writeRequest(path: file.path(percentEncoded: false), sheet: "Q4", range: "B2:C5")

        await spy.consumer.processPending()

        #expect(spy.opened == [file])
        #expect(spy.activated.isEmpty, "there was no tab to front")
        #expect(spy.revealed.map(\.sheet) == ["Q4"])
        #expect(spy.revealed.map(\.range) == ["B2:C5"])
        #expect(spy.pendingRequestFiles().isEmpty, "the request was taken")
    }

    /// A file that is already a tab is fronted rather than opened again.
    @Test func aRequestForAnOpenFileActivatesItsTabRatherThanOpeningIt() async throws {
        let spy = try RevealSpy()
        let file = spy.granted.appendingPathComponent("budget.xlsx")
        spy.openTabs = [file]
        try spy.writeRequest(path: file.path(percentEncoded: false), sheet: "Q4", range: "A1")

        await spy.consumer.processPending()

        #expect(spy.activated == [file])
        #expect(spy.opened.isEmpty)
        #expect(spy.revealed.count == 1)
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    /// Several requests in one pass are handled in a defined order, and all of them are taken.
    @Test func everyPendingRequestIsHandledAndRemoved() async throws {
        let spy = try RevealSpy()
        for name in ["a.xlsx", "b.xlsx", "c.xlsx"] {
            let file = spy.granted.appendingPathComponent(name)
            try spy.writeRequest(path: file.path(percentEncoded: false), sheet: "Q4", range: "A1")
        }

        await spy.consumer.processPending()

        #expect(spy.opened.count == 3)
        #expect(spy.revealed.count == 3)
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    // MARK: - The refusals

    /// **Stale requests are dropped, not replayed.**
    ///
    /// This is the case the startup sweep exists for and the case it would be worst at: without the
    /// cut, launching the app would act on every reveal an agent had ever asked for, scrolling the
    /// user through a history of somebody else's afternoon.
    @Test func aRequestOlderThanTheToleranceIsTakenAndIgnored() async throws {
        let spy = try RevealSpy()
        let file = spy.granted.appendingPathComponent("budget.xlsx")
        try spy.writeRequest(
            path: file.path(percentEncoded: false),
            sheet: "Q4",
            range: "A1",
            requestedAt: Date().addingTimeInterval(-120)
        )

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
        #expect(spy.pendingRequestFiles().isEmpty, "and it will not be reconsidered")
    }

    /// **A path outside the grants opens nothing.**
    ///
    /// Re-checked here rather than trusted because the server wrote it: the user may have revoked
    /// the folder in the seconds since, and the request file has no idea. A reveal cannot be a way
    /// to make the app open a file the agent was never allowed to touch.
    @Test func aRequestForAnUngrantedPathIsTakenAndIgnored() async throws {
        let spy = try RevealSpy()
        try spy.writeRequest(path: "/etc/passwd", sheet: "Q4", range: "A1")

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    /// Malformed JSON is taken and ignored. Left behind, it would be retried forever.
    @Test func aMalformedRequestIsTakenAndIgnored() async throws {
        let spy = try RevealSpy()
        try Data("{ not json at all".utf8).write(to: spy.requestFile(named: "broken"))

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    /// A relative path is not a file anything here can reason about — it would resolve against
    /// whatever the process's working directory happens to be. Refused like any other bad request.
    @Test func aRelativePathIsTakenAndIgnored() async throws {
        let spy = try RevealSpy()
        try spy.writeRequest(path: "budget.xlsx", sheet: "Q4", range: "A1")

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    /// The presence records the app itself publishes live in the same directory. Deleting one
    /// would take the app out of `get_selection` for as long as it took the next refresh.
    @Test func nothingButRequestFilesIsTouched() async throws {
        let spy = try RevealSpy()
        let presence = spy.directory.appendingPathComponent("abc123.json")
        try Data(#"{"path":"/tmp/x.xlsx"}"#.utf8).write(to: presence)
        let stranger = spy.directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: stranger)

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
        #expect(FileManager.default.fileExists(atPath: presence.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: stranger.path(percentEncoded: false)))
    }

    /// A missing directory is the ordinary state of a machine that has never run the server. It is
    /// not an error and it is not a crash.
    @Test func anAbsentDirectoryIsNotAnError() async throws {
        let spy = try RevealSpy(createDirectory: false)

        await spy.consumer.processPending()

        #expect(spy.nothingHappened)
    }

    // MARK: - The round trip

    /// **The two halves agree on bytes.**
    ///
    /// The request is not hand-written here: it is produced by
    /// ``SheetMCP/AppHandshake/requestReveal(url:sheet:range:)``, the code `reveal_range` actually
    /// runs in `opensheets-mcp`. And it only writes at all once the app has published a presence,
    /// so this exercises the whole loop in one process — publisher writes presence, server sees the
    /// app is open and writes a request, consumer reads it and acts.
    ///
    /// Two processes that never speak, agreeing on a directory, a file name and four JSON keys.
    /// This test is the only thing that says they still do.
    @Test func aRequestWrittenByTheRealServerIsUnderstoodByTheRealConsumer() async throws {
        let spy = try RevealSpy()
        let file = spy.granted.appendingPathComponent("budget.xlsx")
        FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: Data())

        // The app half: publish presence, so the server believes the app is open on this file.
        let handshake = AppHandshake(applicationSupport: spy.applicationSupport)
        let publisher = HandshakePublisher(
            handshake: handshake,
            documents: {
                [HandshakeDocumentSnapshot(url: file, sheetName: "Q4", selection: "A1", activeCell: "A1")]
            }
        )
        #expect(publisher.publishNow() == 1)

        // The server half, unmodified.
        #expect(
            handshake.requestReveal(url: file, sheet: "Q4", range: "B2:C5"),
            "the server writes only when it can see the app"
        )

        await spy.consumer.processPending()

        #expect(spy.revealed.map(\.sheet) == ["Q4"])
        #expect(spy.revealed.map(\.range) == ["B2:C5"])
        #expect(
            spy.revealed.first?.url.resolvingSymlinksInPath() == file.resolvingSymlinksInPath(),
            "and about the file the tool was called on"
        )
        #expect(spy.pendingRequestFiles().isEmpty)
    }

    /// And with no presence published, the server writes nothing at all — the degradation the
    /// tools have always promised, still intact now that the app side exists.
    @Test func theServerWritesNoRequestWhenTheAppIsNotThere() async throws {
        let spy = try RevealSpy()
        let file = spy.granted.appendingPathComponent("budget.xlsx")

        let sent = AppHandshake(applicationSupport: spy.applicationSupport)
            .requestReveal(url: file, sheet: "Q4", range: "B2:C5")

        #expect(!sent)
        await spy.consumer.processPending()
        #expect(spy.nothingHappened)
    }

    // MARK: - Applying it to a document

    /// The reveal itself: the command palette's go-to-cell, on a document that did not ask for it.
    ///
    /// The order is the assertion. ``DocumentCore/DocumentModel/activeSheetID``'s `didSet` clears
    /// the selection, so a sheet set after the range would leave the document on the right sheet
    /// with nothing selected — which looks exactly like the request having been ignored.
    @Test func revealingSelectsTheRangeOnTheRequestedSheet() throws {
        let document = try TabSpy().makeDocument(at: URL(fileURLWithPath: "/tmp/opensheets-r/budget.xlsx"))

        let applied = HandshakeReveal.apply(
            HandshakeRevealRequest(url: document.url, sheet: "Q4", range: "B2:C3", requestedAt: Date()),
            to: document
        )

        #expect(applied)
        #expect(document.activeSheet?.name == "Q4")
        #expect(document.selection.activeRange == CellRange(a1: "B2:C3"))
        #expect(document.selection.active == CellRef(a1: "B2"))
    }

    /// A range that is not A1 moves nothing. `reveal_range` validates before it writes, so this is
    /// the belt to that braces — and silently selecting *something* would be worse than nothing.
    @Test func revealingAnUnreadableRangeMovesNothing() throws {
        let document = try TabSpy().makeDocument(at: URL(fileURLWithPath: "/tmp/opensheets-r/budget.xlsx"))
        document.selection.select(try #require(CellRef(a1: "D4")))

        let applied = HandshakeReveal.apply(
            HandshakeRevealRequest(url: document.url, sheet: nil, range: "not a range", requestedAt: Date()),
            to: document
        )

        #expect(!applied)
        #expect(document.selection.active == CellRef(a1: "D4"), "left where the user had it")
    }

    /// A sheet the workbook does not have is ignored rather than guessed at, and the range still
    /// lands — an agent that named a renamed sheet should still get the user to the cells.
    @Test func revealingAnUnknownSheetStillSelectsTheRange() throws {
        let document = try TabSpy().makeDocument(at: URL(fileURLWithPath: "/tmp/opensheets-r/budget.xlsx"))

        let applied = HandshakeReveal.apply(
            HandshakeRevealRequest(url: document.url, sheet: "Nope", range: "A2", requestedAt: Date()),
            to: document
        )

        #expect(applied)
        #expect(document.activeSheet?.name == "Q4")
        #expect(document.selection.active == CellRef(a1: "A2"))
    }
}

// MARK: - Support

/// A consumer whose four effects are recorded rather than performed.
@MainActor
final class RevealSpy {
    /// What the closures did, held apart from the spy so it is fully built before any of them
    /// capture it — which is what lets ``consumer`` be a `let` rather than an implicitly unwrapped
    /// optional that every test would have to trust.
    @MainActor
    final class Recorder {
        var opened: [URL] = []
        var activated: [URL] = []
        var revealed: [HandshakeRevealRequest] = []
        /// Paths the fake tab strip already has open.
        var openTabs: [URL] = []
    }

    let applicationSupport: URL
    let directory: URL
    /// The one folder these tests treat as granted. Everything else is outside the workspace,
    /// which is what makes the refusal test a refusal.
    let granted: URL
    let consumer: HandshakeRevealConsumer

    private let recorder = Recorder()

    var opened: [URL] { recorder.opened }
    var activated: [URL] { recorder.activated }
    var revealed: [HandshakeRevealRequest] { recorder.revealed }
    var openTabs: [URL] {
        get { recorder.openTabs }
        set { recorder.openTabs = newValue }
    }

    /// Nothing fired. The claim every refusal test makes.
    var nothingHappened: Bool { opened.isEmpty && activated.isEmpty && revealed.isEmpty }

    init(createDirectory: Bool = true) throws {
        applicationSupport = try Temp.directory()
        directory = applicationSupport.appendingPathComponent("Handshake")
        granted = try Temp.directory()
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let grantedPath = granted.resolvingSymlinksInPath().path(percentEncoded: false)
        let recorder = recorder
        consumer = HandshakeRevealConsumer(
            directory: directory,
            actions: HandshakeRevealActions(
                isGranted: { url in
                    url.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(grantedPath)
                },
                hasOpenTab: { url in
                    recorder.openTabs.contains { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }
                },
                activate: { url in recorder.activated.append(url) },
                openFile: { url in recorder.opened.append(url) },
                reveal: { request in recorder.revealed.append(request) }
            )
        )
    }

    /// Writes a request the way the server does — same keys, same shapes — without needing a
    /// presence record first. `aRequestWrittenByTheRealServerIsUnderstoodByTheRealConsumer` is the
    /// test that proves this spelling still matches the real writer's.
    func writeRequest(
        path: String,
        sheet: String,
        range: String,
        requestedAt: Date = Date()
    ) throws {
        let payload = JSONValue.object([
            "path": .string(path),
            "sheet": .string(sheet),
            "range": .string(range),
            "requestedAt": .number(requestedAt.timeIntervalSince1970),
        ])
        try Data(payload.rendered.utf8).write(to: requestFile(named: "\(abs(path.hashValue))"))
    }

    func requestFile(named name: String) -> URL {
        directory.appendingPathComponent("\(name).request.json")
    }

    func pendingRequestFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
            ?? []
        return names.filter { $0.hasSuffix(".request.json") }
    }
}
