import Foundation
import SheetModel
@testable import SheetShare
import SheetStore
import TestSupport
import Testing

// MARK: - The world one share link lives in

/// A Cloud Share with nothing faked below the socket.
///
/// # What is real here, and why each piece has to be
///
/// **The database is real.** A `SheetStore` in `.app` mode over a staged application-support
/// directory, which is the same file the subprocess opens through its relocated `HOME`. That is
/// the `SheetMCPTests/Support.swift` topology — two stores over one SQLite file — and it is the
/// reason a revoked row here is a refusal there rather than a test's dictionary agreeing with
/// itself. It is also the only way to plant a *grant*: `UserGrantAuthorization`'s one initialiser
/// is `@MainActor` and takes an open-panel result, so a test cannot mint itself a capability the
/// app could not.
///
/// **The subprocess is real.** The `opensheets-mcp` that `swift build` produced, spawned by
/// ``LinkBridge`` over real pipes, reading the staged store. Every property these cases assert —
/// that `describe` profiles the fixture, that `--read-only` removes tools from a *process*, that
/// a second frame reuses a *pid* — is a property of the executable, and an in-process double
/// would assert none of them.
///
/// **Only the socket is a fake**, and only because the far end is a Cloudflare Worker. Wire
/// contract A is a string on both sides, so the fake carries the same JSON the relay would, and
/// the engine cannot tell the difference: ``FakeRelaySocket/deliver(_:)`` is the relay speaking.
///
/// The struct is implicitly `Sendable` — every stored property is — which is what lets
/// ``waitUntil(_:timeout:sourceLocation:_:)`` close over it without a hop.
struct ShareWorld {
    let scratch: ShareScratch
    /// The granted folder. Under the staged home, so a case about `~` is a case about *this* home.
    let workspace: URL
    /// The app's half of the database: the only place a grant or a link can come from.
    let appStore: SheetStore
    let identityStore: InMemoryDeviceIdentityStore
    let socket: FakeRelaySocket
    let engine: CloudShareEngine
    let log: EngineEventLog

    var store: any ShareLinkStoring { appStore.shareLinks }

    /// - Parameter binary: what `swift build` produced. Injected rather than discovered, the way
    ///   the app injects what `Bundle.main.url(forAuxiliaryExecutable:)` gave it.
    @MainActor
    init(name: String, binary: URL) throws {
        scratch = ShareScratch(name)
        let home = scratch.directory("home")
        workspace = scratch.directory("home/workspace")
        let support = scratch.directory("home/Library/Application Support/OpenSheets")

        let configuration = SheetStore.Configuration(applicationSupport: support)
        appStore = try SheetStore(mode: .app, configuration: configuration)
        // The grant the whole feature rests on, made the only way one can be made.
        try appStore.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: workspace))

        // `CFFIXED_USER_HOME` as well as `HOME`: Foundation resolves the application-support
        // directory through `NSHomeDirectory()`, which reads the password database and ignores
        // `HOME`. Set only `HOME` and the subprocess would read the developer's real grant store
        // — which is both a wrong test and a dangerous one.
        var environment = ProcessInfo.processInfo.environment
        let path = home.path(percentEncoded: false)
        environment["HOME"] = path
        environment["CFFIXED_USER_HOME"] = path
        environment["OPENSHEETS_MCP_LOG"] = "0"

        let socket = FakeRelaySocket()
        self.socket = socket
        let identityStore = InMemoryDeviceIdentityStore()
        self.identityStore = identityStore
        engine = CloudShareEngine(
            store: appStore.shareLinks,
            identityStore: identityStore,
            share: .standard,
            binaryURL: binary,
            configuration: CloudShareEngine.Configuration(
                appVersion: "0.1.0",
                bridge: LinkBridge.Configuration(
                    callTimeout: .seconds(60),
                    idleTimeout: .seconds(300),
                    // Pushed past any plausible run: nothing here may depend on a timer firing,
                    // and a reaper that woke mid-case would make "the pid is stable" flaky rather
                    // than false.
                    reapInterval: .seconds(3600),
                    environment: environment
                )
            ),
            makeSocket: { socket }
        )
        log = EngineEventLog(engine.events)
    }

    /// Belt and braces: every case stops the engine, and a case that failed early might not have.
    /// A leaked subprocess outlives the whole test run.
    func tearDown() {
        let engine = engine
        Task { await engine.stop() }
    }

    // MARK: - Staging

    /// Copies a fixture into the granted folder and returns the path a tool call would name.
    @discardableResult
    func installFixture(_ relativePath: String, as name: String) throws -> String {
        let destination = workspace.appendingPathComponent(name)
        try FixtureLibrary.data(relativePath).write(to: destination)
        return destination.path(percentEncoded: false)
    }

    /// Mints a token under this Mac's identity and records the link, the way the service layer
    /// does. The hash is what the relay would compare; nothing here needs the token again.
    @discardableResult
    func insertLink(name: String, mode: ShareLinkMode) throws -> ShareLinkRecord {
        let identity = try identityStore.loadOrCreate()
        let token = try ShareToken.mint(deviceID: identity.deviceID)
        let record = ShareLinkRecord(
            name: name,
            url: CloudShareConfiguration.standard.linkURL(for: token),
            tokenHash: token.hash,
            mode: mode
        )
        try store.insert(record)
        return record
    }

    // MARK: - Driving the relay

    /// Starts the engine and drives the handshake to `online`, so `sent[0]` is always `hello`.
    func startAndComeOnline() async throws {
        try await engine.start()
        await waitUntil("hello was written") { socket.sent.count == 1 }
        try socket.deliver(RelayMessage.helloAck(version: RelayMessage.version))
        await waitUntil("the engine came online") { await engine.status == .online }
    }

    /// One inbound frame, as the relay would deliver it.
    func deliverRequest(_ requestID: String, link: ShareLinkRecord, body: String, expectsReply: Bool = true) throws {
        try socket.deliver(RelayMessage.request(
            requestID: requestID,
            linkID: link.id.rawValue,
            expectsReply: expectsReply,
            body: body
        ))
    }

    /// The `n`th message the engine wrote, decoded — with the guard that it is a response to
    /// `requestID` and carried a body rather than a failure.
    func okBody(at index: Int, requestID: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String? {
        let sent = try socket.decodedSent()
        guard case let .response(id, outcome) = sent[index] else {
            Issue.record("message \(index) was \(sent[index]), not a response", sourceLocation: sourceLocation)
            return nil
        }
        guard id == requestID else {
            Issue.record("message \(index) answered '\(id)', not '\(requestID)'", sourceLocation: sourceLocation)
            return nil
        }
        guard case let .ok(body) = outcome else {
            Issue.record("'\(requestID)' failed: \(outcome)", sourceLocation: sourceLocation)
            return nil
        }
        return body
    }
}

// MARK: - The suite

/// **The whole local stack, end to end: fake relay → engine → real subprocess → real database.**
///
/// # What this suite is for that the others are not
///
/// `LinkBridgeTests` proves the bridge talks to the binary. `RelayClientTests` proves the socket
/// obeys contract A. Neither proves that the *user flow* works — that a link an owner created,
/// against a folder an owner granted, answers a stranger's `describe` with this workbook's
/// contents and not someone else's, and stops answering the moment the owner revokes it. That
/// sentence spans four components, so it is asserted across all four or not at all.
///
/// Every case is a claim, and every claim is about the shipped artefacts: the grant lives in a
/// real SQLite file, the answer comes out of a real process, and the "no subprocess was spawned"
/// assertions are read off ``LinkBridge/activeLinkIDs`` and
/// ``LinkBridge/processIdentifier(forLink:)`` rather than inferred from a timing.
///
/// `.serialized` because each case spawns processes and the machine is shared; the concurrency
/// that matters is asserted *inside* a case, never across them. Nothing here sleeps: waiting is
/// ``waitUntil(_:timeout:sourceLocation:_:)`` on a condition, and every duration the engine owns
/// is pushed out of the way in ``ShareWorld/init(name:binary:)``.
@Suite("Cloud Share, end to end", .serialized)
struct EndToEndShareTests {
    /// Anchors ``binaryURL`` to *this* bundle. `Bundle.main` under `swift test` is the `xctest`
    /// host in the toolchain, nowhere near the build products.
    private final class BundleAnchor: NSObject {}

    /// Where `swift build` put the executable, or `nil`.
    static var binaryURL: URL? {
        var roots = [Bundle(for: BundleAnchor.self).bundleURL, Bundle.main.bundleURL]
        roots.append(contentsOf: Bundle.allBundles.map(\.bundleURL))
        for root in roots {
            var directory = root
            for _ in 0 ..< 4 {
                let candidate = directory.appendingPathComponent("opensheets-mcp")
                if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                    return candidate
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        return nil
    }

    // MARK: - Frames

    private static let initializeFrame =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private static let initializedNotification =
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    private static let toolsListFrame = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

    /// A `tools/call` frame, built rather than interpolated: the path is a temporary directory
    /// with a UUID in it, and a hand-written string would be one odd character away from
    /// producing a frame the server rejects for a reason that has nothing to do with the test.
    private static func toolCallFrame(id: Int, name: String, arguments: [String: String]) throws -> String {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Reading answers

    /// `result.content[0].text` — what an MCP client would show its model.
    private static func toolText(in frame: String) -> String? {
        guard let result = jsonResult(in: frame),
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { return nil }
        return text
    }

    /// Whether the server answered with a tool error or a protocol error.
    private static func isToolError(_ frame: String) -> Bool {
        guard let object = jsonObject(in: frame) else { return true }
        if object["error"] != nil { return true }
        guard let result = object["result"] as? [String: Any] else { return true }
        return result["isError"] as? Bool == true
    }

    /// The tool names in a `tools/list` answer, sorted.
    private static func toolNames(in frame: String) -> [String] {
        guard let result = jsonResult(in: frame), let tools = result["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { $0["name"] as? String }.sorted()
    }

    private static func jsonObject(in frame: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
    }

    private static func jsonResult(in frame: String) -> [String: Any]? {
        jsonObject(in: frame)?["result"] as? [String: Any]
    }

    /// The corpus fixture these cases profile. Three sheets with three different used ranges,
    /// which is what makes the `describe` assertions below specific to *this* file rather than
    /// true of any workbook.
    private static let fixture = "basic/multi-sheet.xlsx"

    /// Guards the two preconditions this suite cannot create for itself, saying which is missing.
    private static func requirements() -> URL? {
        guard let binary = binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return nil
        }
        guard FixtureLibrary.isAvailable else {
            Issue.record("the Fixtures/ corpus is not reachable; set OPENSHEETS_FIXTURES")
            return nil
        }
        return binary
    }

    // MARK: - (1) The flow the feature exists for

    /// **A shared link answers `describe` with this workbook's contents.**
    ///
    /// The full round trip: a link the owner created, a folder the owner granted, a fixture
    /// inside it, and a stranger's MCP frame arriving over the relay. The assertions are on the
    /// profile text — the sheet names and used ranges that are true of `multi-sheet.xlsx` and of
    /// no other fixture — because "no error came back" would also be satisfied by a server that
    /// answered about the wrong file, and telling those two apart is the entire point.
    @Test @MainActor func aSharedLinkAnswersDescribe() async throws {
        guard let binary = EndToEndShareTests.requirements() else { return }
        let world = try ShareWorld(name: "describe", binary: binary)
        defer { world.tearDown() }
        let path = try world.installFixture(EndToEndShareTests.fixture, as: "multi-sheet.xlsx")
        let link = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.deliverRequest("r-init", link: link, body: EndToEndShareTests.initializeFrame)
        await waitUntil("the handshake was answered") { world.socket.sent.count == 2 }
        try world.deliverRequest("r-describe", link: link, body: EndToEndShareTests.toolCallFrame(
            id: 3, name: "describe", arguments: ["path": path]
        ))
        await waitUntil("describe was answered") { world.socket.sent.count == 3 }

        guard let handshake = try world.okBody(at: 1, requestID: "r-init") else { return }
        #expect(handshake.contains(#""serverInfo""#))
        #expect(handshake.contains("opensheets"))

        guard let body = try world.okBody(at: 2, requestID: "r-describe") else { return }
        let text = try #require(EndToEndShareTests.toolText(in: body), "no tool text in: \(body)")
        #expect(!EndToEndShareTests.isToolError(body), "describe failed: \(text)")

        // The profile of *this* workbook. `multi-sheet.xlsx` is three sheets whose used ranges
        // are deliberately all different, so these lines cannot be true of another fixture.
        #expect(text.contains("multi-sheet.xlsx"))
        #expect(text.contains("3 sheets"))
        #expect(text.contains("Alpha  A1:B2  2 rows x 2 cols"))
        #expect(text.contains("Beta  A1:A2  2 rows x 1 cols  header=row 1"))
        #expect(text.contains("Gamma  C3:C3  1 rows x 1 cols"))
        // And the fixture's own cell contents came back, not just its shape: `Alpha!A1` holds
        // "first" and `Gamma!C3` holds 7, per `basic/multi-sheet.xlsx.expected.json`.
        #expect(text.contains("1 distinct: first"))
        #expect(text.contains("7 .. 7"))
        // Spreadsheet cells are data, and the envelope that says so survives the relay hop.
        #expect(text.contains("<untrusted-spreadsheet-content"))
        #expect(text.contains(path), "the envelope names the file the profile is about")

        #expect(world.log.uses.count == 2, "both frames counted as a use of the link")
        #expect(try world.store.record(id: link.id)?.lastUsedAt != nil, "the row records that it was used")
        await world.engine.stop()
    }

    // MARK: - (2) The mode is a process, not a policy

    /// **A read-only link does not advertise the write tools.**
    ///
    /// Not "refuses to run them" — never offers them, because ``LinkBridge`` spawned the process
    /// with `--read-only` and that process built a smaller registry. The set is asserted whole
    /// rather than by absences: a tool added to the read-only surface is a widening of what every
    /// existing link can do, and it should have to fail a test rather than pass quietly.
    ///
    /// `filter` and `snapshot` are absent on purpose and not by oversight — the first materialises
    /// matching rows and the second writes a restore point, so neither is read-only, and the
    /// remedy if a read-only surface should list them is to split the tool.
    @Test @MainActor func aReadOnlyLinkDoesNotAdvertiseWriteTools() async throws {
        guard let binary = EndToEndShareTests.requirements() else { return }
        let world = try ShareWorld(name: "read-only", binary: binary)
        defer { world.tearDown() }
        let link = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.deliverRequest("r-init", link: link, body: EndToEndShareTests.initializeFrame)
        await waitUntil("the handshake was answered") { world.socket.sent.count == 2 }
        try world.deliverRequest("r-tools", link: link, body: EndToEndShareTests.toolsListFrame)
        await waitUntil("tools/list was answered") { world.socket.sent.count == 3 }

        guard let body = try world.okBody(at: 2, requestID: "r-tools") else { return }
        let names = EndToEndShareTests.toolNames(in: body)

        #expect(names == [
            "describe",
            "find",
            "get_selection",
            "list_files",
            "list_snapshots",
            "list_workspace",
            "open_in_app",
            "read_range",
            "reveal_range",
        ], "the read-only surface changed: \(names)")
        for absent in ["write_range", "delete_file", "delete_rows", "filter", "snapshot", "restore", "set_format"] {
            #expect(!names.contains(absent), "\(absent) must not be reachable through a read-only link")
        }
        await world.engine.stop()
    }

    // MARK: - (3) Revocation, before anything is spawned

    /// **A revoked link answers nothing.**
    ///
    /// The relay's own check is the fast path; this is the authoritative one. The link is revoked
    /// in the database *before* it is ever used, so there is no cached anything to invalidate and
    /// no child to kill — the request is refused on the way in. That the refusal happened before
    /// a process existed is read off the bridge rather than guessed from how quickly the answer
    /// came back: `activeLinkIDs` is empty, this link has no pid, and no child has ever exited,
    /// which together say nothing was ever started.
    @Test @MainActor func aRevokedLinkAnswersNothing() async throws {
        guard let binary = EndToEndShareTests.requirements() else { return }
        let world = try ShareWorld(name: "revoked", binary: binary)
        defer { world.tearDown() }
        let path = try world.installFixture(EndToEndShareTests.fixture, as: "multi-sheet.xlsx")
        let link = try world.insertLink(name: "Ana", mode: .readOnly)
        try world.store.revoke(id: link.id, at: Date())

        try await world.startAndComeOnline()
        try world.deliverRequest("r-describe", link: link, body: EndToEndShareTests.toolCallFrame(
            id: 3, name: "describe", arguments: ["path": path]
        ))
        await waitUntil("the refusal was written") { world.socket.sent.count == 2 }

        let sent = try world.socket.decodedSent()
        #expect(sent[1] == .response(
            requestID: "r-describe",
            outcome: .failed(error: RelayResponseOutcome.Failure.linkRevoked)
        ))
        #expect(world.log.refusals.count == 1)
        #expect(world.log.uses.isEmpty, "a refused request is not a use of the link")

        let bridge = world.engine.subprocesses
        #expect(await bridge.activeLinkIDs.isEmpty)
        #expect(await bridge.processIdentifier(forLink: link.id.rawValue) == nil)
        #expect(await bridge.exitedChildren == 0, "nothing was spawned, so nothing can have exited")
        #expect(try world.store.record(id: link.id)?.lastUsedAt == nil, "a refusal is not a last use")
        await world.engine.stop()
    }

    // MARK: - (4) Notifications

    /// **An id-less frame produces no response.**
    ///
    /// A JSON-RPC notification is owed no answer, and inventing one would put a frame on the wire
    /// the relay has no request to correlate it with. Absence is asserted the only honest way:
    /// a third frame is sent afterwards and *its* answer is the next thing written, so the
    /// notification cannot have produced one — and the answer carries `"id":2`, which also says
    /// the pipe never lost step. Awaiting a line for a frame with no `id` would have consumed
    /// this answer instead, and the desync would be permanent.
    @Test @MainActor func anIdLessFrameProducesNoResponse() async throws {
        guard let binary = EndToEndShareTests.requirements() else { return }
        let world = try ShareWorld(name: "notification", binary: binary)
        defer { world.tearDown() }
        let link = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.deliverRequest("r-init", link: link, body: EndToEndShareTests.initializeFrame)
        await waitUntil("the handshake was answered") { world.socket.sent.count == 2 }

        // The relay marks a frame with no `id` as expecting no reply; the engine honours it.
        try world.deliverRequest(
            "r-note",
            link: link,
            body: EndToEndShareTests.initializedNotification,
            expectsReply: false
        )
        try world.deliverRequest("r-tools", link: link, body: EndToEndShareTests.toolsListFrame)
        await waitUntil("tools/list was answered") { world.socket.sent.count == 3 }

        #expect(world.socket.sent.count == 3, "hello, the handshake's answer, and tools/list's — no fourth")
        guard let body = try world.okBody(at: 2, requestID: "r-tools") else { return }
        #expect(body.contains(#""id":2"#), "the pipe is still in step: this is the answer to *this* call")
        #expect(!EndToEndShareTests.toolNames(in: body).isEmpty)

        // The notification did reach the subprocess and was counted as a use, which is what makes
        // "no response" a decision rather than a frame that went nowhere.
        #expect(world.log.uses.count == 3)
        await world.engine.stop()
    }

    // MARK: - (5) One child per link, not one per call

    /// **A second request reuses the subprocess.**
    ///
    /// Spawning per frame would put a process start on every tool call and throw away the parsed
    /// workbook between them, which is the cost the whole per-link child design exists to avoid.
    /// The pid is the evidence: same number before and after, and `exitedChildren` still zero, so
    /// the second answer came from the process that gave the first — not from a replacement that
    /// happened to be identical.
    @Test @MainActor func aSecondRequestReusesTheSubprocess() async throws {
        guard let binary = EndToEndShareTests.requirements() else { return }
        let world = try ShareWorld(name: "reuse", binary: binary)
        defer { world.tearDown() }
        let path = try world.installFixture(EndToEndShareTests.fixture, as: "multi-sheet.xlsx")
        let link = try world.insertLink(name: "Ana", mode: .readOnly)
        let bridge = world.engine.subprocesses

        try await world.startAndComeOnline()
        try world.deliverRequest("r-init", link: link, body: EndToEndShareTests.initializeFrame)
        await waitUntil("the handshake was answered") { world.socket.sent.count == 2 }
        let firstPID = await bridge.processIdentifier(forLink: link.id.rawValue)

        try world.deliverRequest("r-describe", link: link, body: EndToEndShareTests.toolCallFrame(
            id: 3, name: "describe", arguments: ["path": path]
        ))
        await waitUntil("describe was answered") { world.socket.sent.count == 3 }
        let secondPID = await bridge.processIdentifier(forLink: link.id.rawValue)

        #expect(firstPID != nil, "the first call spawned a child")
        #expect(secondPID == firstPID, "the second call reuses the child rather than spawning another")
        #expect(await bridge.activeLinkIDs == [link.id.rawValue], "one link, one child")
        #expect(await bridge.exitedChildren == 0, "no child died, so the pid cannot be a coincidence")

        // And the reused child served the second call rather than merely surviving it.
        guard let body = try world.okBody(at: 2, requestID: "r-describe") else { return }
        let text = try #require(EndToEndShareTests.toolText(in: body), "no tool text in: \(body)")
        #expect(text.contains("multi-sheet.xlsx"))
        await world.engine.stop()
    }
}
