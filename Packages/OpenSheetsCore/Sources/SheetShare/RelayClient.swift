import Foundation
import SheetModel
import Synchronization

/// One socket to the relay, abstracted so the reconnect logic can be tested without a network.
///
/// # Why a protocol rather than `URLSessionWebSocketTask` directly
///
/// Everything interesting about ``RelayClient`` — hello-before-anything, the backoff schedule,
/// the generation counter that makes a superseded socket harmless — is logic that a test has to
/// be able to drive frame by frame. A client written against `URLSessionWebSocketTask` can only
/// be tested against a real server, which means the reconnect path is tested by unplugging
/// something, which means it is not tested. This is the seam `FileWatcher` draws with its
/// injectable `Configuration`, one level up.
///
/// Implementations are `Sendable` because the client hands one socket to three concurrent tasks:
/// the supervisor that connects, the read loop that drains it, and the keepalive that pings it.
public protocol RelaySocket: Sendable {
    /// Opens the connection. Headers carry the device credential (wire contract A).
    func connect(url: URL, headers: [String: String]) async throws(SheetError)

    /// Writes one line. The relay's framing is one JSON object per WebSocket text message, so
    /// there is no newline to append — the message boundary *is* the frame boundary.
    func send(_ text: String) async throws(SheetError)

    /// The next message. Suspends until one arrives, the socket fails, or it is closed.
    func receive() async throws(SheetError) -> String

    /// A protocol-level ping. See ``RelayClient/Configuration/pingInterval``.
    func ping() async throws(SheetError)

    /// Closes. Idempotent — the client closes sockets it has already given up on.
    func close() async
}

public extension RelaySocket {
    /// Defaulted so a test double that does not model keepalives does not have to write an
    /// empty method. A socket that cannot ping is one the relay will eventually hibernate away
    /// from, which the reconnect path already handles.
    func ping() async throws(SheetError) {}
}

/// What the socket owner saw. Consumed by ``CloudShareEngine``, which turns it into status the
/// settings pane can render and requests the bridge can serve.
public enum RelayEvent: Sendable, Equatable {
    /// A connection attempt is starting. `attempt` is 1 for the first try after a successful
    /// session, so the settings pane can say "retrying" rather than "connecting" the second time.
    case connecting(attempt: Int)

    /// `hello_ack` arrived: the relay has installed the link table and will route requests.
    /// This, not "the socket opened", is what online means — a socket the relay has not
    /// finished reconciling would answer 404 for links this Mac believes are live.
    case online

    /// The connection failed or ended. The client is already backing off; nothing to do.
    case offline(SheetError)

    /// An MCP frame for one of this device's links.
    case request(requestID: String, linkID: String, expectsReply: Bool, body: String)

    /// The relay sent an `error` message and is about to close (`auth_failed`, typically).
    case relayFailure(code: String)

    /// A `type` this build does not know, named so a log line says what was skipped.
    case ignoredUnknownMessage(type: String)

    /// ``RelayClient/stop()`` was called. Always the last event; the stream finishes after it.
    case stopped
}

/// The Mac's end of wire contract A: one outbound WebSocket, reconnected forever.
///
/// # The three properties this type exists to guarantee
///
/// **`hello` is the first thing on every socket.** Not the first thing after a handshake, not
/// the first thing the caller happens to send — the first write, every time, before the read
/// loop starts. The relay routes nothing until it has the link table, so a client that sent a
/// response before its hello would be talking about links the relay had not heard of.
///
/// **A superseded socket cannot speak.** Every connection gets a generation number, and the read
/// loop checks it against the client's current one before doing anything with what it read. This
/// is `FileWatcher`'s `descriptorGeneration` idea, and it is here for the same reason: the
/// alternative is `stop()` blocking until a socket that may never answer answers. `stop()` bumps
/// the generation, closes the socket and returns; whatever was parked inside `receive()` wakes up
/// later, notices it belongs to a connection nobody is listening to, and exits. ``staleMessages``
/// counts the times that happened, because a number that stays at zero in production is how you
/// find out the guard is not needed, and a number that climbs is how you find out it is.
///
/// **Backoff is a pure function of the attempt number.** ``reconnectDelay(attempt:floor:ceiling:)``
/// takes no clock and no state, so the schedule is asserted in a test that runs in microseconds
/// rather than in ten minutes of real waiting. The sleep itself is a closure on
/// ``Configuration`` for the same reason.
public actor RelayClient {
    /// Timings and seams. Defaults are production values; tests turn them down or record them.
    public struct Configuration: Sendable {
        /// The first delay after a failure, and the base the doubling starts from.
        public var reconnectFloor: Duration

        /// The longest the client will ever wait between attempts. A Mac that has been asleep
        /// for a day comes back within a minute rather than within an hour.
        public var reconnectCeiling: Duration

        /// How often to ping. 30 s per wire contract A: long enough that a hibernating Durable
        /// Object stays cheap, short enough that a NAT does not drop the socket between pings.
        public var pingInterval: Duration

        /// Spreads reconnects out so a relay coming back does not get every Mac at once.
        /// Deterministic in tests by passing `{ $0 }`.
        public var jitter: @Sendable (Duration) -> Duration

        /// Where the *backoff* waits, and the one injected clock in this type.
        ///
        /// Tests replace it to record the schedule and return immediately, which is what makes
        /// "the fourth attempt waits eight seconds" an assertion instead of an eight-second
        /// test. Throwing from it stops the client, which is the only way this loop ends early —
        /// see ``RelayClient/stop()`` on why nothing here is cancelled.
        ///
        /// The keepalive deliberately does **not** use it. One seam for both would make every
        /// test that turns time instant into a hot spin: the backoff runs a bounded number of
        /// times and stops, while the ping loop runs for as long as the connection lives.
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(
            reconnectFloor: Duration = .seconds(1),
            reconnectCeiling: Duration = .seconds(60),
            pingInterval: Duration = .seconds(30),
            jitter: @escaping @Sendable (Duration) -> Duration = Configuration.spread,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        ) {
            self.reconnectFloor = reconnectFloor
            self.reconnectCeiling = reconnectCeiling
            self.pingInterval = pingInterval
            self.jitter = jitter
            self.sleep = sleep
        }

        public static let `default` = Configuration()

        /// Down-jitter only: between 75% and 100% of the computed delay. Never longer, so the
        /// ceiling stays a ceiling and a caller reading "at most a minute" is not lied to.
        public static let spread: @Sendable (Duration) -> Duration = { duration in
            .seconds(duration.seconds * Double.random(in: 0.75 ... 1.0))
        }
    }

    /// A socket failure as a `SheetError`.
    ///
    /// ``RelaySocket`` promises `throws(SheetError)`, but the client holds `any RelaySocket`, and
    /// a typed throw through an existential erases to `any Error`. Rather than pretend otherwise
    /// with a cast that could be wrong, the conversion is written down once: a `SheetError`
    /// passes through unchanged, and anything else becomes the IO case it already was.
    static func socketFailure(_ error: any Error) -> SheetError {
        error as? SheetError ?? .fileNotReadable(path: "relay socket", underlying: "\(error)")
    }

    /// Exponential backoff, capped. Pure — no clock, no state, no randomness — so the schedule
    /// is a table a test can write down: 1, 2, 4, 8, 16, 32, 60, 60 … seconds.
    public static func reconnectDelay(attempt: Int, floor: Duration, ceiling: Duration) -> Duration {
        guard attempt > 1 else { return min(floor, ceiling) }
        var delay = floor
        // Bounded rather than `pow`: doubling a `Duration` 40 times overflows, and an attempt
        // counter on a Mac that has been offline for a week reaches numbers like that.
        for _ in 0 ..< min(attempt - 1, 40) {
            delay *= 2
            if delay >= ceiling { return ceiling }
        }
        return min(delay, ceiling)
    }

    // MARK: - Configuration

    private let identity: DeviceIdentity
    private let agentURL: URL
    private let appVersion: String
    private let configuration: Configuration
    private let makeSocket: @Sendable () -> any RelaySocket

    /// Every event, in order. Unbounded: a dropped ``RelayEvent/request(requestID:linkID:expectsReply:body:)``
    /// is a client call that hangs until the relay's 120 s timeout, which is the worst failure
    /// this component has.
    nonisolated public let events: AsyncStream<RelayEvent>
    nonisolated private let continuation: AsyncStream<RelayEvent>.Continuation

    // MARK: - Actor state

    /// The link table `hello` carries. Replaced by ``setLinks(_:)``, amended by ``upsert(_:)``.
    private var links: [RelayLink]

    /// Bumped on every connection attempt and by ``stop()``. See the type's note.
    private var generation: UInt64 = 0

    /// Consecutive failed attempts. Reset to zero by `hello_ack`, so a socket that lived for an
    /// hour and then dropped reconnects in a second rather than in a minute.
    private var reconnectAttempt = 0

    private var isRunning = false
    private var socket: (any RelaySocket)?
    private var supervisor: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?

    /// Whether a read loop is currently attached to a live socket.
    private var connectionLive = false
    private var connectionEnded: CheckedContinuation<Void, Never>?

    /// True between `hello_ack` and the connection ending.
    public private(set) var isOnline = false

    /// How many messages arrived on a socket the client had already moved past. Zero in a
    /// healthy process; see the type's note for why it is counted rather than ignored.
    public private(set) var staleMessages = 0

    public init(
        identity: DeviceIdentity,
        agentURL: URL,
        appVersion: String,
        links: [RelayLink] = [],
        configuration: Configuration = .default,
        makeSocket: @escaping @Sendable () -> any RelaySocket
    ) {
        self.identity = identity
        self.agentURL = agentURL
        self.appVersion = appVersion
        self.links = links
        self.configuration = configuration
        self.makeSocket = makeSocket
        let (stream, continuation) = AsyncStream<RelayEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    // MARK: - Lifecycle

    /// Starts connecting, and keeps connecting until ``stop()``. A second call is a no-op.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        supervisor = Task { [weak self] in await self?.supervise() }
    }

    /// Closes the socket, stops reconnecting, and finishes ``events`` — promptly.
    ///
    /// "Promptly" is the requirement. A `receive()` parked on a socket the relay will never
    /// answer must not be able to hold the app's shutdown, so nothing here waits for the read
    /// loop: the generation bump makes whatever it eventually returns a no-op.
    ///
    /// Nothing is cancelled, either, and that is deliberate. The three tasks this client runs
    /// end by *checking* — the reader and the keepalive on the generation, the supervisor on
    /// `isRunning` — so the teardown path is the same code that runs on every reconnect, rather
    /// than a second path that only executes when somebody quits and is therefore the one nobody
    /// has exercised. The cost is a keepalive that sleeps out its last interval before noticing.
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        isOnline = false
        connectionLive = false
        let socket = self.socket
        self.socket = nil
        reader = nil
        keepalive = nil
        supervisor = nil
        connectionEnded?.resume()
        connectionEnded = nil
        await socket?.close()
        continuation.yield(.stopped)
        continuation.finish()
    }

    /// Replaces the link table sent by the next `hello`. Does not touch the relay's copy — a
    /// wholesale replacement is what `hello` is for, and doing it mid-session would race the
    /// per-link acks.
    public func setLinks(_ links: [RelayLink]) {
        self.links = links
    }

    /// Records a link locally and, if connected, tells the relay now.
    ///
    /// Offline is not an error here. The link table travels in the next `hello`, which is
    /// exactly the "revoke while offline" case in the plan: the app has already stopped
    /// bridging for that link, so the relay's copy being a few seconds stale changes nothing.
    public func upsert(_ link: RelayLink) async {
        links.removeAll { $0.linkID == link.linkID }
        links.append(link)
        await send(.linkUpsert(link))
    }

    /// Best effort. A response that cannot be sent is a client call the relay answers with its
    /// own offline error once the 120 s budget runs out — worse than sending it, better than
    /// tearing down a socket that may be fine.
    @discardableResult
    public func send(_ message: RelayMessage) async -> Bool {
        guard let socket, isOnline else { return false }
        do {
            let text = try message.encodedJSON()
            try await socket.send(text)
            return true
        } catch {
            // The socket is done. Closing it wakes the read loop, which runs the normal
            // reconnect path — one place that decides what a dead connection means.
            continuation.yield(.offline(Self.socketFailure(error)))
            await socket.close()
            return false
        }
    }

    // MARK: - The supervisor

    private func supervise() async {
        while isRunning {
            reconnectAttempt += 1
            let attempt = reconnectAttempt
            generation &+= 1
            let generation = self.generation
            continuation.yield(.connecting(attempt: attempt))

            let socket = makeSocket()
            self.socket = socket
            do {
                try await socket.connect(url: agentURL, headers: headers)
                let hello = try RelayMessage.hello(
                    deviceID: identity.deviceID,
                    appVersion: appVersion,
                    links: links
                ).encodedJSON()
                try await socket.send(hello)
            } catch {
                guard isRunning, generation == self.generation else { return }
                continuation.yield(.offline(Self.socketFailure(error)))
                await socket.close()
                guard await backOff(attempt: attempt) else { return }
                continue
            }

            connectionLive = true
            startReading(generation: generation, socket: socket)
            startPinging(generation: generation, socket: socket)
            await waitForConnectionToEnd()
            guard isRunning else { return }
            guard await backOff(attempt: reconnectAttempt) else { return }
        }
    }

    private var headers: [String: String] {
        [
            DeviceIdentity.Header.authorization: DeviceIdentity.Header.bearer(identity.secret),
            DeviceIdentity.Header.device: identity.deviceID,
        ]
    }

    /// Sleeps the backoff for `attempt`. `false` means stop trying — the injected sleep threw,
    /// which is what cancellation looks like from in here.
    private func backOff(attempt: Int) async -> Bool {
        let delay = configuration.jitter(Self.reconnectDelay(
            attempt: attempt,
            floor: configuration.reconnectFloor,
            ceiling: configuration.reconnectCeiling
        ))
        do {
            try await configuration.sleep(delay)
        } catch {
            return false
        }
        return isRunning
    }

    private func waitForConnectionToEnd() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Checked inside the closure, which runs before the suspension and on this actor:
            // a connection that failed before we parked must not park us forever.
            guard connectionLive else { return continuation.resume() }
            connectionEnded = continuation
        }
    }

    private func endConnection(generation: UInt64) {
        guard generation == self.generation else { return }
        connectionLive = false
        isOnline = false
        reader = nil
        keepalive = nil
        connectionEnded?.resume()
        connectionEnded = nil
    }

    // MARK: - Reading

    private func startReading(generation: UInt64, socket: any RelaySocket) {
        reader = Task { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let text = try await socket.receive()
                    guard await self.consume(text, generation: generation) else { return }
                } catch {
                    await self.readFailed(RelayClient.socketFailure(error), generation: generation)
                    return
                }
            }
        }
    }

    /// Returns whether the read loop should keep going.
    private func consume(_ text: String, generation: UInt64) -> Bool {
        guard generation == self.generation else {
            staleMessages += 1
            return false
        }
        let message: RelayMessage
        do {
            message = try RelayMessage.decode(text)
        } catch {
            // A known type missing a field, or a line that is not JSON. Contract A says this is
            // a violation rather than a forward-compatibility case, so the socket goes.
            continuation.yield(.offline(error))
            endConnection(generation: generation)
            return false
        }
        switch message {
        case .helloAck:
            reconnectAttempt = 0
            isOnline = true
            continuation.yield(.online)
        case .ack:
            // Nothing to do: `upsert` already recorded the link locally, and the ack only says
            // the relay agrees. Logged by its absence — a link that never acks still works,
            // because `hello` re-sends the whole table on the next connect.
            break
        case let .request(requestID, linkID, expectsReply, body):
            continuation.yield(.request(
                requestID: requestID,
                linkID: linkID,
                expectsReply: expectsReply,
                body: body
            ))
        case let .failure(code):
            continuation.yield(.relayFailure(code: code))
        case let .unknown(type):
            continuation.yield(.ignoredUnknownMessage(type: type))
        case .hello, .linkUpsert, .response:
            // App → relay messages, arriving from the relay. A relay that sent one is confused;
            // ignoring it is the forward-compatible answer and costs nothing.
            continuation.yield(.ignoredUnknownMessage(type: "app-to-relay message echoed back"))
        }
        return true
    }

    private func readFailed(_ error: SheetError, generation: UInt64) async {
        guard generation == self.generation else {
            staleMessages += 1
            return
        }
        continuation.yield(.offline(error))
        await socket?.close()
        endConnection(generation: generation)
    }

    // MARK: - Keepalive

    private func startPinging(generation: UInt64, socket: any RelaySocket) {
        let interval = configuration.pingInterval
        keepalive = Task { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard let self, await self.generation == generation else { return }
                do {
                    try await socket.ping()
                } catch {
                    // Closing is the whole response: the read loop wakes with an error and the
                    // supervisor reconnects. A ping failure handled anywhere else would be a
                    // second place that decides what a dead socket means.
                    await socket.close()
                    return
                }
            }
        }
    }
}

// MARK: - The production socket

/// `URLSessionWebSocketTask`, wrapped to the shape ``RelayClient`` needs.
///
/// # Why one socket object per connection
///
/// `URLSessionWebSocketTask` is not restartable: once it has failed or been cancelled, the only
/// way forward is a new task. So ``RelayClient`` is handed a factory rather than an instance,
/// and this type owns exactly one task for its whole life. That also means the reconnect path
/// cannot accidentally reuse a half-dead socket, which is the bug the generation counter would
/// otherwise be papering over.
public final class URLSessionRelaySocket: RelaySocket {
    private let session: URLSession
    private let task = Mutex<URLSessionWebSocketTask?>(nil)

    /// - Parameter session: injectable so a caller can pin a configuration; the default is the
    ///   shared session, which is what every other outbound request in a Mac app uses.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, headers: [String: String]) async throws(SheetError) {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let created = session.webSocketTask(with: request)
        // The default is 1 MB, which would truncate an ordinary `read_range` result. 32 MB
        // matches the bridge's frame ceiling and `FrameReader.maximumFrameBytes`, so a frame
        // the subprocess was willing to emit is a frame this socket is willing to carry.
        created.maximumMessageSize = 32 * 1024 * 1024
        task.withLock { slot in
            slot?.cancel(with: .goingAway, reason: nil)
            slot = created
        }
        created.resume()
    }

    public func send(_ text: String) async throws(SheetError) {
        guard let task = task.withLock({ $0 }) else {
            throw .fileNotWritable(path: "relay socket", underlying: "the socket is not connected")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw .fileNotWritable(path: "relay socket", underlying: "\(error)")
        }
    }

    public func receive() async throws(SheetError) -> String {
        guard let task = task.withLock({ $0 }) else {
            throw .fileNotReadable(path: "relay socket", underlying: "the socket is not connected")
        }
        do {
            switch try await task.receive() {
            case let .string(text):
                return text
            case let .data(data):
                // Contract A is text frames. A binary frame is not a protocol error worth
                // dropping a socket over, so it is decoded and handed on; the message decoder
                // rejects it if it is not JSON.
                return String(decoding: data, as: UTF8.self)
            @unknown default:
                throw SheetError.invalidArgument(
                    name: "relay message",
                    reason: "the socket delivered a frame of a kind this build does not know"
                )
            }
        } catch let error as SheetError {
            throw error
        } catch {
            throw .fileNotReadable(path: "relay socket", underlying: "\(error)")
        }
    }

    public func ping() async throws(SheetError) {
        guard let task = task.withLock({ $0 }) else {
            throw .fileNotWritable(path: "relay socket", underlying: "the socket is not connected")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw .fileNotWritable(path: "relay socket", underlying: "\(error)")
        }
    }

    public func close() async {
        task.withLock { slot in
            slot?.cancel(with: .normalClosure, reason: nil)
            slot = nil
        }
    }
}

// MARK: - Durations

extension Duration {
    /// Seconds as a `Double`. `Duration`'s own arithmetic is integral, and the jitter factor is
    /// not, so the conversion happens once here rather than at three call sites.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
