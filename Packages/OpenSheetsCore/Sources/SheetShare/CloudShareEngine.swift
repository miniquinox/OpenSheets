import Foundation
import SheetModel
import SheetStore

/// Cloud Share, assembled: the socket, the subprocesses, and the one decision that sits between
/// them — *is this link still allowed to ask*.
///
/// # The authoritative half of revocation
///
/// The relay rejects revoked token hashes, and that is the fast path. This is the one that
/// matters. Every inbound request re-reads the link's row from the local database before a byte
/// reaches a subprocess, so a relay that is stale, wrong, or hostile cannot resurrect a link the
/// owner revoked. The rule is `AppModel.swift:447-449`'s, restated for links: *anything acting on
/// outside input reads the store live, never a cached array.* There is deliberately no link cache
/// in this type, and adding one would be a security regression rather than an optimisation.
///
/// The check fails **closed**. A database error, an id that is not a ULID, a row that is not
/// there — all of them refuse the request. The cost of failing closed is a link that stops
/// working while the disk is sick; the cost of failing open is a revoked link that answers.
///
/// # What "off" costs
///
/// Nothing, structurally. This object is only constructed when the flag and the toggle are both
/// on (Agent 7 owns that gate), and it touches nothing until ``start()``: no Keychain read, no
/// socket, no subprocess. ``stop()`` puts it back — the socket closes, every child dies, and the
/// links keep existing as rows nobody is serving.
public actor CloudShareEngine {
    /// Where the Mac's end of the feature is, as far as the settings pane is concerned.
    ///
    /// Deliberately not `GlassUI.CloudShareStatus`: this target cannot see GlassUI, and it
    /// should not — a status word is identity and belongs to the component that draws it, while
    /// this is a fact about a socket. `CloudShareService` maps one onto the other.
    public enum Status: Sendable, Equatable {
        case stopped
        case connecting
        case online
        /// Carries the reason for the detail line under the status row.
        case offline(reason: String)
    }

    /// Everything the layer above wants to hear about.
    public enum Event: Sendable, Equatable {
        case status(Status)
        /// A request arrived for a live link and was bridged. Drives the row's "Last used".
        case linkUsed(linkID: String, at: Date)
        /// A request arrived for a link that is revoked, unknown, or unreadable, and was refused
        /// before anything was spawned.
        case linkRefused(linkID: String, reason: String)
        /// Something worth a log line that is not a status change. Never carries a token.
        case diagnostic(String)
    }

    /// Composed from the two halves' configurations plus the app's own facts.
    public struct Configuration: Sendable {
        /// Sent in `hello`, so a relay log can tell which build a device is running.
        public var appVersion: String
        public var relay: RelayClient.Configuration
        public var bridge: LinkBridge.Configuration
        public var now: @Sendable () -> Date

        public init(
            appVersion: String = "0.1.0",
            relay: RelayClient.Configuration = .default,
            bridge: LinkBridge.Configuration = .default,
            now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.appVersion = appVersion
            self.relay = relay
            self.bridge = bridge
            self.now = now
        }

        public static let `default` = Configuration()
    }

    private let store: any ShareLinkStoring
    private let identityStore: any DeviceIdentityStoring
    private let share: CloudShareConfiguration
    private let configuration: Configuration
    private let makeSocket: @Sendable () -> any RelaySocket
    private let bridge: LinkBridge

    nonisolated public let events: AsyncStream<Event>
    nonisolated private let continuation: AsyncStream<Event>.Continuation

    private var relay: RelayClient?
    private var consumer: Task<Void, Never>?

    public private(set) var status: Status = .stopped

    /// - Parameters:
    ///   - store: the share-link table. Read on every inbound request; see the type's note.
    ///   - identityStore: this Mac's device identity. Touched at ``start()`` and never before,
    ///     which is what keeps "off reads no Keychain item" true.
    ///   - binaryURL: the embedded `opensheets-mcp`. Injected — see ``LinkBridge/init(binaryURL:configuration:)``.
    ///   - makeSocket: one socket per connection attempt. Defaults to the real one.
    public init(
        store: any ShareLinkStoring,
        identityStore: any DeviceIdentityStoring,
        share: CloudShareConfiguration = .standard,
        binaryURL: URL,
        configuration: Configuration = .default,
        makeSocket: @escaping @Sendable () -> any RelaySocket = { URLSessionRelaySocket() }
    ) {
        self.store = store
        self.identityStore = identityStore
        self.share = share
        self.configuration = configuration
        self.makeSocket = makeSocket

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        var bridgeConfiguration = configuration.bridge
        // The bridge's failure detail becomes an engine diagnostic rather than being dropped:
        // "the subprocess died" is the sentence somebody debugging a dead link needs, and it is
        // never on the wire, because the wire only carries the three pinned spellings.
        let sink = continuation
        bridgeConfiguration.log = { detail in sink.yield(.diagnostic(detail)) }
        bridge = LinkBridge(binaryURL: binaryURL, configuration: bridgeConfiguration)
    }

    // MARK: - Lifecycle

    /// Reads the device identity, loads the link table, and starts connecting.
    ///
    /// Throws only for the things that make the feature impossible rather than merely offline: a
    /// device identity the Keychain will not give up, and a relay origin that is not a URL. A
    /// relay that is simply down is not an error — that is what the reconnect loop is for.
    public func start() async throws(SheetError) {
        guard relay == nil else { return }
        let identity = try identityStore.loadOrCreate()
        let agentURL = try share.agentURL()
        let links = try relayLinks()

        let client = RelayClient(
            identity: identity,
            agentURL: agentURL,
            appVersion: configuration.appVersion,
            links: links,
            configuration: configuration.relay,
            makeSocket: makeSocket
        )
        relay = client
        consumer = Task { [weak self] in
            for await event in client.events {
                await self?.handle(event)
            }
        }
        await bridge.startReaping()
        await client.start()
    }

    /// Closes the socket and kills every subprocess. The rows stay; nothing is serving them.
    public func stop() async {
        // Stopping the relay finishes its event stream, which ends the consumer loop by itself.
        // That is the same path a relay-side close takes, rather than a cancellation path
        // nothing else in this feature uses — see ``RelayClient/stop()``.
        await relay?.stop()
        relay = nil
        consumer = nil
        await bridge.shutDown()
        set(.stopped)
    }

    /// This Mac's identity, minted on first use. The service layer needs the `deviceID` to mint
    /// link tokens, and minting has to work while the relay is unreachable.
    public func identity() throws(SheetError) -> DeviceIdentity {
        try identityStore.loadOrCreate()
    }

    /// The bridge, for the app's quit path and for tests that assert on subprocesses.
    nonisolated public var subprocesses: LinkBridge { bridge }

    // MARK: - Link table

    /// Replaces the relay's copy of the link table with what the database says now.
    public func refreshLinks() async {
        guard let relay else { return }
        do {
            let links = try relayLinks()
            await relay.setLinks(links)
        } catch {
            continuation.yield(.diagnostic("the share-link table could not be read: \(error.message)"))
        }
    }

    /// Pushes one created or revoked link. Offline is not a failure — the next `hello` carries
    /// the whole table, and the local refusal below has already taken effect regardless.
    public func upsert(_ record: ShareLinkRecord) async {
        await relay?.upsert(RelayLink(
            linkID: record.id.rawValue,
            tokenHash: record.tokenHash,
            revoked: !record.isActive
        ))
        if !record.isActive { await bridge.stop(linkID: record.id.rawValue) }
    }

    /// Replaces the whole table, for the caller that already has the records in hand.
    public func setLinks(_ records: [ShareLinkRecord]) async {
        await relay?.setLinks(records.map { record in
            RelayLink(
                linkID: record.id.rawValue,
                tokenHash: record.tokenHash,
                revoked: !record.isActive
            )
        })
    }

    private func relayLinks() throws(SheetError) -> [RelayLink] {
        let records: [ShareLinkRecord]
        do {
            records = try store.all()
        } catch let error as SheetError {
            throw error
        } catch {
            throw .databaseError(operation: "list share links", underlying: "\(error)")
        }
        return records.map { record in
            RelayLink(linkID: record.id.rawValue, tokenHash: record.tokenHash, revoked: !record.isActive)
        }
    }

    // MARK: - The event loop

    private func handle(_ event: RelayEvent) async {
        switch event {
        case let .connecting(attempt):
            // Only the first attempt reads as "Connecting…". A retry keeps whatever reason the
            // failure just put on the status, because "retrying" on its own tells the owner
            // less than "the relay refused the device credential" does.
            if attempt <= 1 { set(.connecting) }
        case .online:
            set(.online)
        case let .offline(error):
            set(.offline(reason: error.message))
        case let .request(requestID, linkID, expectsReply, body):
            // Concurrently across links, serialised within one by the bridge. A request that
            // took the actor's turn for its whole round trip would make one slow tool call block
            // every other link's.
            Task { [weak self] in
                await self?.route(requestID: requestID, linkID: linkID, expectsReply: expectsReply, body: body)
            }
        case let .relayFailure(code):
            continuation.yield(.diagnostic("the relay closed the socket: \(code)"))
        case let .ignoredUnknownMessage(type):
            continuation.yield(.diagnostic("ignored a relay message of an unknown kind: \(type)"))
        case .stopped:
            set(.stopped)
        }
    }

    /// One inbound frame, from the live revocation check to the answer.
    private func route(requestID: String, linkID: String, expectsReply: Bool, body: String) async {
        guard let record = liveRecord(linkID: linkID) else {
            continuation.yield(.linkRefused(linkID: linkID, reason: "the link is revoked or unknown"))
            // Kill anything this link had running: a revoke that leaves a subprocess alive is a
            // capability the owner believes they withdrew.
            await bridge.stop(linkID: linkID)
            if expectsReply {
                await relay?.send(.response(
                    requestID: requestID,
                    outcome: .failed(error: RelayResponseOutcome.Failure.linkRevoked)
                ))
            }
            return
        }

        let at = configuration.now()
        do {
            try store.touchLastUsed(id: record.id, at: at)
        } catch {
            // Not fatal: "Last used" is evidence for the owner, not part of the boundary.
            continuation.yield(.diagnostic("could not record last use of link \(linkID)"))
        }
        continuation.yield(.linkUsed(linkID: linkID, at: at))

        let outcome = await bridge.exchange(
            linkID: linkID,
            mode: record.mode,
            body: body,
            expectsReply: expectsReply
        )
        guard expectsReply, let outcome else { return }
        await relay?.send(.response(requestID: requestID, outcome: outcome))
    }

    /// The link, if it exists and is active, read from the database *now*.
    ///
    /// Fails closed on every uncertainty — see the type's note.
    private func liveRecord(linkID: String) -> ShareLinkRecord? {
        guard let id = ULID(rawValue: linkID) else { return nil }
        guard let record = try? store.record(id: id), record.isActive else { return nil }
        return record
    }

    private func set(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        continuation.yield(.status(status))
    }
}
