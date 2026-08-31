import Foundation
import SheetModel
@testable import SheetShare
import Testing

// MARK: - Test doubles

/// One delivery to a parked read: a message, or the failure that ends the connection.
typealias FakeSocketDelivery = Result<String, SheetError>

/// A socket the test drives frame by frame.
///
/// Everything ``RelayClient`` is worth testing — hello before anything else, the backoff table,
/// a superseded socket going quiet — is invisible against a real server and obvious against this.
/// The one deliberate infidelity is ``wakesParkedReadOnClose``: a real socket fails its pending
/// `receive()` when it is cancelled, and setting this to `false` models the socket that does
/// not, which is exactly the case the generation counter exists for.
///
/// `@unchecked Sendable` because the lock, not the compiler, is what makes it safe — the client
/// hands one of these to three tasks at once.
final class FakeRelaySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [FakeSocketDelivery] = []
    private var waiter: CheckedContinuation<FakeSocketDelivery, Never>?
    private var written: [String] = []
    private var connectionCount = 0
    private var closeCount = 0
    private var seenHeaders: [String: String] = [:]
    private var seenURL: URL?
    private var sendFailure: SheetError?

    /// Set to make ``connect(url:headers:)`` refuse, for the backoff cases.
    let connectFailure: SheetError?

    /// Whether ``close()`` fails a parked ``receive()``. See the type's note.
    let wakesParkedReadOnClose: Bool

    init(connectFailure: SheetError? = nil, wakesParkedReadOnClose: Bool = true) {
        self.connectFailure = connectFailure
        self.wakesParkedReadOnClose = wakesParkedReadOnClose
    }

    static let refused = SheetError.fileNotReadable(path: "relay socket", underlying: "the test refused it")

    // MARK: What the test observes

    var sent: [String] { lock.withLock { written } }
    var connects: Int { lock.withLock { connectionCount } }
    var closes: Int { lock.withLock { closeCount } }
    var headers: [String: String] { lock.withLock { seenHeaders } }
    var url: URL? { lock.withLock { seenURL } }

    func decodedSent() throws -> [RelayMessage] {
        try sent.map { try RelayMessage.decode($0) }
    }

    // MARK: What the test does

    /// Hands the client one message. If nothing is reading, it queues.
    func deliver(_ text: String) {
        resume(.success(text))
    }

    func deliver(_ message: RelayMessage) throws {
        deliver(try message.encodedJSON())
    }

    /// Fails the client's next read, the way a dropped connection does.
    func failRead(_ error: SheetError = FakeRelaySocket.refused) {
        resume(.failure(error))
    }

    /// Makes every later write fail, the way a half-open socket does.
    func refuseSends(_ error: SheetError = .fileNotWritable(path: "relay socket", underlying: "refused")) {
        lock.withLock { sendFailure = error }
    }

    private func resume(_ delivery: FakeSocketDelivery) {
        lock.lock()
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: delivery)
            return
        }
        inbox.append(delivery)
        lock.unlock()
    }

    // MARK: RelaySocket

    func connect(url: URL, headers: [String: String]) async throws(SheetError) {
        lock.withLock {
            connectionCount += 1
            seenURL = url
            seenHeaders = headers
        }
        if let connectFailure { throw connectFailure }
    }

    func send(_ text: String) async throws(SheetError) {
        let failure: SheetError? = lock.withLock {
            if sendFailure == nil { written.append(text) }
            return sendFailure
        }
        if let failure { throw failure }
    }

    func receive() async throws(SheetError) -> String {
        let delivery = await parkedRead()
        switch delivery {
        case let .success(text): return text
        case let .failure(error): throw error
        }
    }

    private func parkedRead() async -> FakeSocketDelivery {
        await withCheckedContinuation { continuation in
            lock.lock()
            if inbox.isEmpty {
                waiter = continuation
                lock.unlock()
            } else {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            }
        }
    }

    func close() async {
        // The lock is taken in a scoped, non-async helper: `NSLock.lock()`/`unlock()` are
        // unavailable from an async context, and rightly so.
        takeWaiterOnClose()?.resume(
            returning: .failure(.fileNotReadable(path: "relay socket", underlying: "closed"))
        )
    }

    private func takeWaiterOnClose() -> CheckedContinuation<FakeSocketDelivery, Never>? {
        lock.withLock {
            closeCount += 1
            guard wakesParkedReadOnClose, let waiting = waiter else { return nil }
            waiter = nil
            return waiting
        }
    }
}

/// Hands out a fresh ``FakeRelaySocket`` per connection attempt and keeps them all, the way
/// ``URLSessionRelaySocket`` is one-shot in production.
///
/// `failuresBeforeSuccess` scripts a relay that is down and then comes back, which is what the
/// backoff-reset case needs and what a Mac waking from sleep actually meets.
final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [FakeRelaySocket] = []
    private let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int = 0) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    var count: Int { lock.withLock { sockets.count } }

    func socket(_ index: Int) -> FakeRelaySocket? {
        lock.withLock { index < sockets.count ? sockets[index] : nil }
    }

    func next() -> any RelaySocket {
        lock.lock()
        let index = sockets.count
        lock.unlock()
        let socket = FakeRelaySocket(connectFailure: index < failuresBeforeSuccess ? FakeRelaySocket.refused : nil)
        lock.withLock { sockets.append(socket) }
        return socket
    }
}

/// Collects a client's events off its stream so a test can ask what happened without racing the
/// consumer.
final class RelayEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [RelayEvent] = []
    private var task: Task<Void, Never>?

    init(_ events: AsyncStream<RelayEvent>) {
        task = Task { [self] in
            for await event in events {
                lock.withLock { collected.append(event) }
            }
        }
    }

    deinit { task?.cancel() }

    var events: [RelayEvent] { lock.withLock { collected } }

    var requests: [RelayEvent] {
        events.filter { if case .request = $0 { true } else { false } }
    }
}

/// Records what was slept for instead of sleeping.
///
/// `limit` is the point of the throw: ``RelayClient`` treats a throwing sleep as cancellation and
/// stops reconnecting, so a test can watch exactly eight attempts and then let the client go, in
/// microseconds rather than in the two minutes those eight delays would really take.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    private let limit: Int

    init(limit: Int = .max) { self.limit = limit }

    var durations: [Duration] { lock.withLock { recorded } }

    struct Stopped: Error {}

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            let count = lock.withLock { () -> Int in
                recorded.append(duration)
                return recorded.count
            }
            if count >= limit { throw Stopped() }
        }
    }
}

/// Waits until `condition` holds, or fails the test saying what it was waiting for.
///
/// The first thousand turns are `Task.yield()`, which costs no wall-clock time at all: for
/// everything that is pure logic — a socket handshake against a fake, a backoff schedule against
/// a recorded clock — the loop finishes in microseconds and the suite stays instant. After that
/// it starts pausing a millisecond a turn, because the cases that drive a real subprocess are
/// waiting on a process to be scheduled and read from a pipe, and yielding a cooperative thread
/// cannot make that happen sooner.
///
/// `timeout` is a bound on failure, not a delay: nothing waits for it in the passing case, and a
/// test that reaches it fails with a sentence rather than hanging the run.
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    var turns = 0
    while ContinuousClock.now < deadline {
        if await condition() { return }
        turns += 1
        if turns < 1000 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    Issue.record("timed out waiting until \(what)", sourceLocation: sourceLocation)
}

// MARK: - The suite

/// **The Mac's end of wire contract A.**
///
/// Three properties, and most cases here are one of them: `hello` goes first on every socket, the
/// backoff schedule is the table the plan wrote down, and a socket the client has moved past
/// cannot speak. The fourth thing asserted is that `stop()` returns even when the socket it is
/// stopping never will — which is the reason the generation counter exists rather than a join.
@Suite("The relay client, driven frame by frame")
struct RelayClientTests {
    private static let agentURL = URL(string: "wss://relay.example.workers.dev/agent")
        ?? URL(fileURLWithPath: "/dev/null")

    /// Timings that never wait: the sleep returns immediately and the jitter is the identity, so
    /// the schedule a test reads is the schedule the code computed.
    private static func timings(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> RelayClient.Configuration {
        RelayClient.Configuration(
            reconnectFloor: .seconds(1),
            reconnectCeiling: .seconds(60),
            pingInterval: .seconds(30),
            jitter: { $0 },
            sleep: sleep
        )
    }

    private func makeClient(
        identity: DeviceIdentity,
        links: [RelayLink] = [],
        configuration: RelayClient.Configuration = RelayClientTests.timings(),
        socket: @escaping @Sendable () -> any RelaySocket
    ) -> RelayClient {
        RelayClient(
            identity: identity,
            agentURL: RelayClientTests.agentURL,
            appVersion: "0.1.0",
            links: links,
            configuration: configuration,
            makeSocket: socket
        )
    }

    static func link(_ suffix: String, revoked: Bool = false) -> RelayLink {
        RelayLink(
            linkID: "01HZY6X7QG9F0Z8T3B5N2K4M6\(suffix)",
            tokenHash: String(repeating: "a", count: 63) + suffix,
            revoked: revoked
        )
    }

    private static let scheduleToTheCeiling: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8),
        .seconds(16), .seconds(32), .seconds(60), .seconds(60),
    ]

    // MARK: - Hello first

    /// The first thing written to a fresh socket is `hello`, carrying the whole link table.
    @Test func helloIsTheFirstThingOnTheSocket() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity, links: [Self.link("P")]) { socket }

        await client.start()
        await waitUntil("the client has written something") { !socket.sent.isEmpty }

        let sent = try socket.decodedSent()
        #expect(sent.count == 1, "nothing may go out before the relay has the link table")
        guard case let .hello(deviceID, appVersion, links) = try #require(sent.first) else {
            Issue.record("the first message was \(String(describing: sent.first)), not hello")
            return
        }
        #expect(deviceID == identity.deviceID)
        #expect(appVersion == "0.1.0")
        #expect(links == [Self.link("P")])
        await client.stop()
    }

    /// The socket presents the device credential in the two headers the contract names.
    @Test func theSocketPresentsTheDeviceCredential() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }

        await client.start()
        await waitUntil("the socket has been connected") { socket.connects == 1 }

        #expect(socket.url == Self.agentURL)
        #expect(socket.headers[DeviceIdentity.Header.authorization] == "Bearer \(identity.secret)")
        #expect(socket.headers[DeviceIdentity.Header.device] == identity.deviceID)
        #expect(socket.headers.count == 2, "the socket carries the credential and nothing else")
        await client.stop()
    }

    /// Online means `hello_ack`, not "the socket opened". A relay that has not installed the
    /// link table would 404 links this Mac believes are live.
    @Test func theClientIsOnlineOnlyAfterTheRelayAcknowledgesHello() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }
        let log = RelayEventLog(client.events)

        await client.start()
        await waitUntil("hello was sent") { !socket.sent.isEmpty }
        #expect(await client.isOnline == false, "a socket the relay has not acknowledged is not online")

        try socket.deliver(RelayMessage.helloAck(version: RelayMessage.version))
        await waitUntil("the client came online") { await client.isOnline }

        #expect(log.events.contains(.connecting(attempt: 1)))
        #expect(log.events.contains(.online))
        await client.stop()
    }

    /// A request from the relay reaches the consumer with its frame untouched.
    @Test func aRequestIsHandedOnVerbatim() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }
        let log = RelayEventLog(client.events)
        let body = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"describe"}}"#

        await client.start()
        try socket.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }
        try socket.deliver(RelayMessage.request(
            requestID: "r-9",
            linkID: Self.link("P").linkID,
            expectsReply: true,
            body: body
        ))
        await waitUntil("the request arrived") { !log.requests.isEmpty }

        #expect(log.requests == [.request(
            requestID: "r-9",
            linkID: Self.link("P").linkID,
            expectsReply: true,
            body: body
        )])
        await client.stop()
    }

    /// An unknown message type is skipped and the socket survives it — the forward-compatibility
    /// half of the contract, asserted at the socket rather than at the decoder.
    @Test func anUnknownMessageTypeDoesNotDropTheConnection() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }
        let log = RelayEventLog(client.events)

        await client.start()
        try socket.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }
        socket.deliver(#"{"type":"weather_report","temperature":11}"#)
        await waitUntil("the unknown type was reported") {
            log.events.contains(.ignoredUnknownMessage(type: "weather_report"))
        }

        #expect(await client.isOnline, "an unknown message is not a reason to reconnect")
        #expect(socket.connects == 1)
        await client.stop()
    }

    /// A revoke reaches the relay as a `link_upsert` the moment it happens.
    @Test func upsertGoesOutOnALiveSocket() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }

        await client.start()
        try socket.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }
        await client.upsert(Self.link("P", revoked: true))
        await waitUntil("the upsert was written") { socket.sent.count == 2 }

        let sent = try socket.decodedSent()
        #expect(sent[1] == .linkUpsert(Self.link("P", revoked: true)))
        await client.stop()
    }

    /// A write that fails closes the socket rather than being retried in place: the read loop is
    /// the one place that decides what a dead connection means.
    @Test func aFailedWriteGivesUpOnTheSocket() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket()
        let client = makeClient(identity: identity) { socket }

        await client.start()
        try socket.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }
        socket.refuseSends()
        let delivered = await client.send(.response(requestID: "r-1", outcome: .ok(body: "{}")))

        #expect(delivered == false)
        #expect(socket.closes >= 1, "a socket that cannot be written to is a socket to give up on")
        await client.stop()
    }

    // MARK: - Backoff

    /// The schedule is a pure function, so it is asserted as the table the plan wrote down.
    @Test func theBackoffScheduleDoublesToItsCeiling() {
        let delays = (1 ... 8).map { attempt in
            RelayClient.reconnectDelay(attempt: attempt, floor: .seconds(1), ceiling: .seconds(60))
        }
        #expect(delays == Self.scheduleToTheCeiling)
        #expect(
            RelayClient.reconnectDelay(attempt: 400, floor: .seconds(1), ceiling: .seconds(60)) == .seconds(60),
            "an attempt counter from a week offline must not overflow its way past the ceiling"
        )
    }

    /// A relay that refuses every connection is retried on exactly that schedule.
    @Test func aRefusedConnectionIsRetriedOnTheSchedule() async throws {
        let identity = try DeviceIdentity.mint()
        let recorder = SleepRecorder(limit: 8)
        let client = makeClient(identity: identity, configuration: Self.timings(sleep: recorder.sleep)) {
            FakeRelaySocket(connectFailure: FakeRelaySocket.refused)
        }

        await client.start()
        await waitUntil("eight attempts have been made") { recorder.durations.count == 8 }

        #expect(recorder.durations == Self.scheduleToTheCeiling)
        await client.stop()
    }

    /// A session that reached `hello_ack` resets the schedule: a socket that lived for an hour
    /// and then dropped reconnects in a second, not in wherever the counter had got to.
    @Test func aSuccessfulSessionResetsTheBackoff() async throws {
        let identity = try DeviceIdentity.mint()
        let recorder = SleepRecorder()
        let sockets = SocketSequence(failuresBeforeSuccess: 3)
        let client = makeClient(identity: identity, configuration: Self.timings(sleep: recorder.sleep)) {
            sockets.next()
        }

        await client.start()
        await waitUntil("three refusals were backed off") { recorder.durations.count == 3 }
        await waitUntil("the fourth socket connected") { sockets.socket(3)?.sent.isEmpty == false }
        let live = try #require(sockets.socket(3))
        try live.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }
        live.failRead()
        await waitUntil("the dropped session was backed off") { recorder.durations.count == 4 }

        #expect(recorder.durations == [.seconds(1), .seconds(2), .seconds(4), .seconds(1)])
        await client.stop()
    }

    // MARK: - Generations

    /// `stop()` returns while a socket is still parked inside `receive()`, and whatever that
    /// socket says afterwards is discarded rather than delivered.
    ///
    /// This is the whole reason for the generation counter. A `stop()` that joined its read loop
    /// would hang here — the fake is built not to wake on close, which is the real behaviour of a
    /// socket whose peer has gone away without saying so.
    @Test func aSupersededSocketCannotSpeak() async throws {
        let identity = try DeviceIdentity.mint()
        let socket = FakeRelaySocket(wakesParkedReadOnClose: false)
        let client = makeClient(identity: identity) { socket }
        let log = RelayEventLog(client.events)

        await client.start()
        try socket.deliver(RelayMessage.helloAck(version: 1))
        await waitUntil("online") { await client.isOnline }

        // Returns promptly: nothing here waits for the parked read.
        await client.stop()
        #expect(socket.closes == 1)

        try socket.deliver(RelayMessage.request(
            requestID: "r-late",
            linkID: Self.link("P").linkID,
            expectsReply: true,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        ))
        await waitUntil("the late message was discarded") { await client.staleMessages == 1 }

        #expect(log.requests.isEmpty, "a request from a socket nobody is listening to is not a request")
        #expect(await client.isOnline == false)
    }

    /// `stop()` closes the socket and stops reconnecting: no further attempt is ever made.
    @Test func stopEndsTheReconnectLoop() async throws {
        let identity = try DeviceIdentity.mint()
        let sockets = SocketSequence()
        let client = makeClient(identity: identity) { sockets.next() }
        let log = RelayEventLog(client.events)

        await client.start()
        await waitUntil("the first socket was made") { sockets.count == 1 }
        await client.stop()
        let connectsAtStop = sockets.count
        // Let anything that was going to reconnect have its turn.
        for _ in 0 ..< 1000 { await Task.yield() }

        #expect(sockets.count == connectsAtStop, "stop means stop, not 'until the next failure'")
        #expect(try #require(sockets.socket(0)).closes >= 1)
        await waitUntil("the event stream finished") { log.events.last == .stopped }
    }

    /// Starting twice opens one socket. The app calls `start()` from a toggle a user can flip
    /// faster than a socket opens.
    @Test func startingTwiceOpensOneSocket() async throws {
        let identity = try DeviceIdentity.mint()
        let sockets = SocketSequence()
        let client = makeClient(identity: identity) { sockets.next() }

        await client.start()
        await client.start()
        await waitUntil("a socket was made") { sockets.count >= 1 }
        for _ in 0 ..< 500 { await Task.yield() }

        #expect(sockets.count == 1)
        await client.stop()
    }
}
