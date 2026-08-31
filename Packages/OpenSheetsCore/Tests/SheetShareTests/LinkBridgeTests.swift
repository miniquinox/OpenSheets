import Foundation
import SheetModel
@testable import SheetShare
import SheetStore
import Testing

// MARK: - Scratch space

/// A directory that removes itself.
///
/// Under `NSTemporaryDirectory()` rather than `/tmp`, for the reason the MCP suite's copy gives:
/// `/tmp` is a symlink to `/private/tmp`, and a subprocess rooted there would be exercising
/// symlink resolution by accident.
final class ShareScratch: @unchecked Sendable {
    let url: URL

    init(_ name: String = "case") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-share-tests")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func directory(_ name: String) -> URL {
        let target = url.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}

/// Collects a ``CloudShareEngine``'s events without racing its consumer.
final class EngineEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [CloudShareEngine.Event] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<CloudShareEngine.Event>) {
        task = Task { [self] in
            for await event in events {
                lock.withLock { collected.append(event) }
            }
        }
    }

    deinit { task?.cancel() }

    var events: [CloudShareEngine.Event] { lock.withLock { collected } }

    var refusals: [CloudShareEngine.Event] {
        events.filter { if case .linkRefused = $0 { true } else { false } }
    }

    var uses: [CloudShareEngine.Event] {
        events.filter { if case .linkUsed = $0 { true } else { false } }
    }
}

// MARK: - The suite

/// **The bridge, against the binary that ships.**
///
/// Every case here spawns the real `opensheets-mcp` and talks JSON-RPC to it over real pipes, for
/// the reason `ShippedBinaryTests` exists: the properties being asserted — that `--read-only`
/// removes the write tools from a *process*, that a notification consumes no answer, that a dead
/// child is reported rather than hung on — are properties of the executable and the pipe, and a
/// test that drove `MCPServer` in-process would assert none of them.
///
/// The subprocess gets its own `HOME` **and** `CFFIXED_USER_HOME`, so it reads a store staged
/// here rather than the developer's. That is Foundation's own resolution of the application
/// support directory, not a switch in our code: there is deliberately no argument that relocates
/// the grant database.
///
/// Serialised because each case spawns processes and the machine is a shared resource; the
/// bridge's own concurrency is asserted inside a case rather than across them.
@Suite("The link bridge, against the built binary", .serialized)
struct LinkBridgeTests {
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

    /// A `HOME` the subprocess can have to itself, with the application-support directory the
    /// store lives in already made.
    private static func stagedHome(_ name: String) -> (scratch: ShareScratch, home: URL, support: URL) {
        let scratch = ShareScratch(name)
        let home = scratch.directory("home")
        let support = scratch.directory("home/Library/Application Support/OpenSheets")
        return (scratch, home, support)
    }

    private static func environment(home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = home.path(percentEncoded: false)
        environment["HOME"] = path
        environment["CFFIXED_USER_HOME"] = path
        environment["OPENSHEETS_MCP_LOG"] = "0"
        return environment
    }

    /// Bridge timings for a test: the reaper is pushed far enough out that only an explicit
    /// ``LinkBridge/reapIdle(asOf:)`` reaps, so nothing here depends on wall-clock time.
    private static func bridgeConfiguration(
        home: URL,
        maximumFrameBytes: Int = 32 * 1024 * 1024,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> LinkBridge.Configuration {
        LinkBridge.Configuration(
            callTimeout: .seconds(60),
            idleTimeout: .seconds(300),
            reapInterval: .seconds(3600),
            maximumFrameBytes: maximumFrameBytes,
            environment: environment(home: home),
            log: log
        )
    }

    private static let initializeFrame =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#
    private static let initializedNotification =
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    private static let toolsListFrame = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#

    /// The link id the single-link cases use. A real ULID, because the engine parses it.
    private static let linkID = "01HZY6X7QG9F0Z8T3B5N2K4M6P"

    // MARK: - The handshake

    /// The bridge writes a frame to the real binary and gets that frame's answer back.
    @Test func theBridgeCompletesAnMCPHandshake() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("handshake")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )
        defer { Task { await bridge.shutDown() } }

        let outcome = await bridge.exchange(
            linkID: Self.linkID,
            mode: .readOnly,
            body: Self.initializeFrame,
            expectsReply: true
        )

        guard case let .ok(body) = try #require(outcome) else {
            Issue.record("the handshake failed: \(String(describing: outcome))")
            return
        }
        #expect(body.contains(#""id":1"#))
        #expect(body.contains(#""serverInfo""#))
        #expect(body.contains("opensheets"))
        #expect(await bridge.activeLinkIDs == [Self.linkID])
        await bridge.shutDown()
    }

    /// A read-only link's `tools/list` does not mention a write tool. Not "refuses to run one" —
    /// does not advertise one, because the process was spawned with a registry that has none.
    @Test func aReadOnlyLinkNeverAdvertisesWriteTools() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("read-only")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        let listing = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.toolsListFrame, expectsReply: true
        )

        guard case let .ok(body) = try #require(listing) else {
            Issue.record("tools/list failed: \(String(describing: listing))")
            return
        }
        // The presence assertion pins the spelling the absence assertions rely on: if the server
        // rendered its JSON differently, this would fail rather than letting the `!contains`
        // below pass for the wrong reason.
        #expect(body.contains(#""name":"read_range""#))
        #expect(body.contains(#""name":"describe""#))
        #expect(!body.contains(#""name":"write_range""#))
        #expect(!body.contains(#""name":"delete_file""#))
        await bridge.shutDown()
    }

    /// The contrast case: without the flag the same binary advertises the write tools, so the
    /// case above is testing `--read-only` rather than something the server does anyway.
    @Test func aReadWriteLinkAdvertisesTheWriteTools() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("read-write")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readWrite, body: Self.initializeFrame, expectsReply: true
        )
        let listing = await bridge.exchange(
            linkID: Self.linkID, mode: .readWrite, body: Self.toolsListFrame, expectsReply: true
        )

        guard case let .ok(body) = try #require(listing) else {
            Issue.record("tools/list failed: \(String(describing: listing))")
            return
        }
        #expect(body.contains(#""name":"write_range""#))
        #expect(body.contains(#""name":"read_range""#))
        await bridge.shutDown()
    }

    /// A notification is written and forgotten, and the call after it gets its own answer.
    ///
    /// This is D8's second half. Awaiting a line for a frame with no `id` would consume the
    /// *next* request's response and desync the pipe permanently, so the assertion that matters
    /// is not "the notification returned nil" but "`tools/list` after it answered `tools/list`".
    @Test func aNotificationConsumesNoAnswer() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("notification")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        let notification = await bridge.exchange(
            linkID: Self.linkID,
            mode: .readOnly,
            body: Self.initializedNotification,
            expectsReply: false
        )
        let listing = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.toolsListFrame, expectsReply: true
        )

        #expect(notification == nil, "a frame with no id is owed no answer")
        guard case let .ok(body) = try #require(listing) else {
            Issue.record("tools/list failed: \(String(describing: listing))")
            return
        }
        #expect(body.contains(#""id":2"#), "the pipe is still in step: this is the answer to *this* call")
        await bridge.shutDown()
    }

    /// Two calls on one link are serialised, and each gets its own answer.
    @Test func concurrentCallsOnOneLinkTakeTurns() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("serialised")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        async let first = bridge.exchange(
            linkID: Self.linkID,
            mode: .readOnly,
            body: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
            expectsReply: true
        )
        async let second = bridge.exchange(
            linkID: Self.linkID,
            mode: .readOnly,
            body: #"{"jsonrpc":"2.0","id":8,"method":"ping"}"#,
            expectsReply: true
        )
        let answers = await [first, second]

        let bodies = answers.compactMap { outcome -> String? in
            if case let .ok(body) = outcome { return body }
            return nil
        }
        #expect(bodies.count == 2)
        #expect(bodies.contains { $0.contains(#""id":7"#) })
        #expect(bodies.contains { $0.contains(#""id":8"#) })
        #expect(
            bodies.filter { $0.contains(#""id":7"#) }.count == 1,
            "no answer may be delivered twice — that would mean the pipe lost step"
        )
        await bridge.shutDown()
    }

    // MARK: - Reaping

    /// An idle child is killed, and the operating system agrees it is gone.
    ///
    /// `exitedChildren` is counted from `Process.terminationHandler`, so this asserts the
    /// process actually exited rather than only that the bridge stopped tracking it.
    @Test func anIdleChildIsReapedAndTheNextCallSpawnsAFreshOne() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("reap")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        let firstPID = await bridge.processIdentifier(forLink: Self.linkID)
        #expect(firstPID != nil)

        await bridge.reapIdle(asOf: Date().addingTimeInterval(3600))
        #expect(await bridge.activeLinkIDs.isEmpty)
        await waitUntil("the reaped child exited") { await bridge.exitedChildren >= 1 }

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        let secondPID = await bridge.processIdentifier(forLink: Self.linkID)

        #expect(secondPID != nil)
        #expect(secondPID != firstPID, "the next call spawns a new child rather than resurrecting one")
        await bridge.shutDown()
    }

    /// A child in use is not reaped: the deadline is measured from its last call, not from when
    /// it started.
    @Test func aBusyChildSurvivesTheReaper() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("busy")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        _ = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )
        await bridge.reapIdle(asOf: Date())

        #expect(await bridge.activeLinkIDs == [Self.linkID])
        await bridge.shutDown()
    }

    // MARK: - Failures

    /// A frame over the ceiling is refused before a process exists.
    @Test func aFrameOverTheCeilingIsRefusedWithoutSpawning() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = LinkBridgeTests.stagedHome("oversize")
        let bridge = LinkBridge(
            binaryURL: binary,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home, maximumFrameBytes: 64)
        )

        let outcome = await bridge.exchange(
            linkID: Self.linkID,
            mode: .readOnly,
            body: String(repeating: "x", count: 65),
            expectsReply: true
        )

        #expect(outcome == .failed(error: RelayResponseOutcome.Failure.frameTooLarge))
        #expect(await bridge.activeLinkIDs.isEmpty, "an oversize frame must not cost a process")
        await bridge.shutDown()
    }

    /// A child that dies mid-call is reported as a failure, and the next call gets a new one.
    ///
    /// The stand-in is a script rather than the real server because a crash has to be made to
    /// happen on cue: this one reads its frame and exits without answering, then — once the test
    /// plants a marker file — answers normally. Both halves of the plan's requirement land in one
    /// case: the in-flight call is answered `subprocess_failed`, and the call after it is served.
    @Test func aCrashedChildIsReportedAndTheNextCallRespawns() async throws {
        let staged = LinkBridgeTests.stagedHome("crash")
        let marker = staged.scratch.url.appendingPathComponent("answer-now")
        let script = staged.scratch.url.appendingPathComponent("flaky-server.sh")
        let source = """
        #!/bin/sh
        read -r line
        if [ -f "\(marker.path(percentEncoded: false))" ]; then
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"served":true}}'
        else
          exit 9
        fi
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false)
        )

        let diagnostics = DiagnosticLog()
        let bridge = LinkBridge(
            binaryURL: script,
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home, log: diagnostics.append)
        )

        let crashed = await bridge.exchange(
            linkID: Self.linkID, mode: .readWrite, body: Self.initializeFrame, expectsReply: true
        )
        #expect(crashed == .failed(error: RelayResponseOutcome.Failure.subprocessFailed))
        #expect(await bridge.activeLinkIDs.isEmpty, "a dead child is dropped rather than kept as a corpse")
        #expect(
            diagnostics.lines.contains { $0.contains("link \(Self.linkID)") },
            "the reason belongs in a log line, not on the wire"
        )

        try Data("go".utf8).write(to: marker)
        let served = await bridge.exchange(
            linkID: Self.linkID, mode: .readWrite, body: Self.initializeFrame, expectsReply: true
        )

        guard case let .ok(body) = try #require(served) else {
            Issue.record("the respawned child did not answer: \(String(describing: served))")
            return
        }
        #expect(body.contains(#""served":true"#))
        await bridge.shutDown()
    }

    /// A binary that is not there fails the call rather than the app.
    @Test func aMissingBinaryFailsTheCallRatherThanTheProcess() async throws {
        let staged = LinkBridgeTests.stagedHome("missing")
        let bridge = LinkBridge(
            binaryURL: staged.scratch.url.appendingPathComponent("no-such-binary"),
            configuration: LinkBridgeTests.bridgeConfiguration(home: staged.home)
        )

        let outcome = await bridge.exchange(
            linkID: Self.linkID, mode: .readOnly, body: Self.initializeFrame, expectsReply: true
        )

        #expect(outcome == .failed(error: RelayResponseOutcome.Failure.subprocessFailed))
        #expect(await bridge.activeLinkIDs.isEmpty)
        await bridge.shutDown()
    }

    // MARK: - The engine, end to end over a real database

    /// A live link's frame reaches the binary, and the answer goes back on the socket.
    @Test func aLiveLinkIsBridgedAndItsUseRecorded() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "bridged", binary: binary)
        defer { world.tearDown() }
        let record = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.socket.deliver(RelayMessage.request(
            requestID: "r-1",
            linkID: record.id.rawValue,
            expectsReply: true,
            body: Self.initializeFrame
        ))
        await waitUntil("the response was written") { world.socket.sent.count == 2 }

        let sent = try world.socket.decodedSent()
        guard case let .response(requestID, outcome) = sent[1] else {
            Issue.record("the second message was \(sent[1]), not a response")
            return
        }
        #expect(requestID == "r-1")
        guard case let .ok(body) = outcome else {
            Issue.record("the bridged call failed: \(outcome)")
            return
        }
        #expect(body.contains(#""id":1"#))
        #expect(world.log.uses.count == 1)
        #expect(try world.store.record(id: record.id)?.lastUsedAt != nil, "the row records that it was used")
        await world.engine.stop()
    }

    /// **A revoke recorded in the database is honoured on the very next request, with no restart.**
    ///
    /// The relay's own check is the fast path; this is the authoritative one. The link is used
    /// once so a subprocess exists, then revoked in the database directly — no engine call, no
    /// reconnect, nothing that could be mistaken for the engine having been told — and the next
    /// frame is refused, with the child killed rather than left running.
    @Test func aRevokeInTheDatabaseIsHonouredOnTheNextRequest() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "revoke", binary: binary)
        defer { world.tearDown() }
        let record = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.socket.deliver(RelayMessage.request(
            requestID: "r-1",
            linkID: record.id.rawValue,
            expectsReply: true,
            body: Self.initializeFrame
        ))
        await waitUntil("the first call was answered") { world.socket.sent.count == 2 }
        #expect(await world.engine.subprocesses.activeLinkIDs == [record.id.rawValue])

        try world.store.revoke(id: record.id, at: Date())

        try world.socket.deliver(RelayMessage.request(
            requestID: "r-2",
            linkID: record.id.rawValue,
            expectsReply: true,
            body: Self.toolsListFrame
        ))
        await waitUntil("the second call was answered") { world.socket.sent.count == 3 }

        let sent = try world.socket.decodedSent()
        #expect(sent[2] == .response(
            requestID: "r-2",
            outcome: .failed(error: RelayResponseOutcome.Failure.linkRevoked)
        ))
        #expect(world.log.refusals.count == 1)
        #expect(
            await world.engine.subprocesses.activeLinkIDs.isEmpty,
            "a revoke that leaves a subprocess alive is a capability the owner believes they withdrew"
        )
        await world.engine.stop()
    }

    /// A link id the database has never heard of is refused, and costs no process.
    @Test func anUnknownLinkIsRefusedWithoutSpawning() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "unknown", binary: binary)
        defer { world.tearDown() }

        try await world.startAndComeOnline()
        try world.socket.deliver(RelayMessage.request(
            requestID: "r-1",
            linkID: "01HZY6X7QG9F0Z8T3B5N2K4M6Q",
            expectsReply: true,
            body: Self.initializeFrame
        ))
        await waitUntil("the refusal was written") { world.socket.sent.count == 2 }

        let sent = try world.socket.decodedSent()
        #expect(sent[1] == .response(
            requestID: "r-1",
            outcome: .failed(error: RelayResponseOutcome.Failure.linkRevoked)
        ))
        #expect(await world.engine.subprocesses.activeLinkIDs.isEmpty)
        await world.engine.stop()
    }

    /// A link id that is not even a ULID is refused the same way, rather than reaching anything
    /// that would try to parse it. The relay's `linkId` is a string this Mac chose, so a value
    /// that is not one means the relay is confused or lying; both answers are the same.
    @Test func aMalformedLinkIdIsRefused() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "malformed", binary: binary)
        defer { world.tearDown() }

        try await world.startAndComeOnline()
        try world.socket.deliver(RelayMessage.request(
            requestID: "r-1",
            linkID: "../../etc/passwd",
            expectsReply: true,
            body: Self.initializeFrame
        ))
        await waitUntil("the refusal was written") { world.socket.sent.count == 2 }

        let sent = try world.socket.decodedSent()
        #expect(sent[1] == .response(
            requestID: "r-1",
            outcome: .failed(error: RelayResponseOutcome.Failure.linkRevoked)
        ))
        #expect(await world.engine.subprocesses.activeLinkIDs.isEmpty)
        await world.engine.stop()
    }

    /// The engine's `hello` carries the link table the database holds, revoked rows included —
    /// which is what heals a relay whose copy drifted.
    @Test func helloCarriesTheTableTheDatabaseHolds() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "hello", binary: binary)
        defer { world.tearDown() }
        let live = try world.insertLink(name: "Ana", mode: .readOnly)
        let dead = try world.insertLink(name: "Bo", mode: .readWrite)
        try world.store.revoke(id: dead.id, at: Date())

        try await world.engine.start()
        await waitUntil("hello was written") { !world.socket.sent.isEmpty }

        let sent = try world.socket.decodedSent()
        guard case let .hello(_, _, links) = sent[0] else {
            Issue.record("the first message was \(sent[0]), not hello")
            return
        }
        #expect(links.count == 2)
        #expect(links.contains(RelayLink(linkID: live.id.rawValue, tokenHash: live.tokenHash, revoked: false)))
        #expect(links.contains(RelayLink(linkID: dead.id.rawValue, tokenHash: dead.tokenHash, revoked: true)))
        await world.engine.stop()
    }

    /// Switching Cloud Share off ends every subprocess the links had running.
    @Test func stoppingTheEngineKillsEveryChild() async throws {
        guard let binary = LinkBridgeTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let world = try EngineWorld(name: "stop", binary: binary)
        defer { world.tearDown() }
        let record = try world.insertLink(name: "Ana", mode: .readOnly)

        try await world.startAndComeOnline()
        try world.socket.deliver(RelayMessage.request(
            requestID: "r-1",
            linkID: record.id.rawValue,
            expectsReply: true,
            body: Self.initializeFrame
        ))
        await waitUntil("the call was answered") { world.socket.sent.count == 2 }
        #expect(await world.engine.subprocesses.activeLinkIDs.count == 1)

        await world.engine.stop()

        #expect(await world.engine.subprocesses.activeLinkIDs.isEmpty)
        #expect(await world.engine.status == .stopped)
        #expect(world.socket.closes >= 1)
    }
}

// MARK: - Engine fixtures

/// Collects the bridge's log lines.
final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    var lines: [String] { lock.withLock { collected } }

    var append: @Sendable (String) -> Void {
        { [self] line in lock.withLock { collected.append(line) } }
    }
}

/// An engine wired to a real database, a real binary and a fake socket.
///
/// The database is the real `SheetStore` over a staged application-support directory rather than
/// an in-memory double, because the property under test is "the row the database holds decides",
/// and a fake store would be asserting that the test's own dictionary decides.
struct EngineWorld {
    let scratch: ShareScratch
    let sheetStore: SheetStore
    let socket: FakeRelaySocket
    let engine: CloudShareEngine
    let log: EngineEventLog

    var store: any ShareLinkStoring { sheetStore.shareLinks }

    init(name: String, binary: URL) throws {
        scratch = ShareScratch(name)
        let home = scratch.directory("home")
        let support = scratch.directory("home/Library/Application Support/OpenSheets")
        sheetStore = try SheetStore(mode: .app, configuration: SheetStore.Configuration(applicationSupport: support))

        var environment = ProcessInfo.processInfo.environment
        let path = home.path(percentEncoded: false)
        environment["HOME"] = path
        environment["CFFIXED_USER_HOME"] = path
        environment["OPENSHEETS_MCP_LOG"] = "0"

        let socket = FakeRelaySocket()
        self.socket = socket
        engine = CloudShareEngine(
            store: sheetStore.shareLinks,
            identityStore: InMemoryDeviceIdentityStore(),
            share: .standard,
            binaryURL: binary,
            configuration: CloudShareEngine.Configuration(
                appVersion: "0.1.0",
                bridge: LinkBridge.Configuration(
                    callTimeout: .seconds(60),
                    idleTimeout: .seconds(300),
                    reapInterval: .seconds(3600),
                    environment: environment
                )
            ),
            makeSocket: { socket }
        )
        log = EngineEventLog(engine.events)
    }

    func tearDown() {
        // Belt and braces: every case stops the engine, and a case that failed early might not
        // have, and a leaked subprocess outlives the test run.
        let engine = engine
        Task { await engine.stop() }
    }

    @discardableResult
    func insertLink(name: String, mode: ShareLinkMode) throws -> ShareLinkRecord {
        let identity = try engineIdentity()
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

    private func engineIdentity() throws -> DeviceIdentity {
        try DeviceIdentity.mint()
    }

    /// Starts the engine and drives the relay handshake to `online`.
    func startAndComeOnline() async throws {
        try await engine.start()
        await waitUntil("hello was written") { socket.sent.count == 1 }
        try socket.deliver(RelayMessage.helloAck(version: RelayMessage.version))
        await waitUntil("the engine came online") { await engine.status == .online }
    }
}
