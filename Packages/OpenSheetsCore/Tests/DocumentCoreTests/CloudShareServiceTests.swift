import DocumentCore
import Foundation
import GlassUI
import SheetModel
import SheetShare
import SheetStore
import Synchronization
import Testing

// MARK: - Doubles

/// A share-link table that remembers what it was asked, so "off reads nothing" is a count rather
/// than a promise.
private final class CountingShareLinkStore: ShareLinkStoring {
    struct Counts: Sendable, Equatable {
        var reads = 0
        var writes = 0
    }

    private struct State {
        var records: [ShareLinkRecord] = []
        var counts = Counts()
    }

    private let state = Mutex(State())

    init(seed: [ShareLinkRecord] = []) {
        state.withLock { $0.records = seed }
    }

    var counts: Counts { state.withLock { $0.counts } }
    var records: [ShareLinkRecord] { state.withLock { $0.records } }

    func insert(_ record: ShareLinkRecord) throws {
        state.withLock { current in
            current.counts.writes += 1
            current.records.insert(record, at: 0)
        }
    }

    /// Newest first, like the ``Database`` conformance.
    func all() throws -> [ShareLinkRecord] {
        state.withLock { current in
            current.counts.reads += 1
            return current.records
        }
    }

    func record(id: ULID) throws -> ShareLinkRecord? {
        state.withLock { current in
            current.counts.reads += 1
            return current.records.first { $0.id == id }
        }
    }

    func revoke(id: ULID, at date: Date) throws {
        state.withLock { current in
            current.counts.writes += 1
            guard let index = current.records.firstIndex(where: { $0.id == id }) else { return }
            current.records[index].revokedAt = date
        }
    }

    func delete(id: ULID) throws {
        state.withLock { current in
            current.counts.writes += 1
            current.records.removeAll { $0.id == id }
        }
    }

    func touchLastUsed(id: ULID, at date: Date) throws {
        state.withLock { current in
            current.counts.writes += 1
            guard let index = current.records.firstIndex(where: { $0.id == id }) else { return }
            current.records[index].lastUsedAt = date
        }
    }

    func activeRecord(tokenHash: String) throws -> ShareLinkRecord? {
        state.withLock { current in
            current.counts.reads += 1
            return current.records.first { $0.tokenHash == tokenHash && $0.isActive }
        }
    }
}

/// The Keychain's stand-in, counting the reads that must not happen while the feature is off.
private final class CountingIdentityStore: DeviceIdentityStoring {
    private let inner = InMemoryDeviceIdentityStore()
    private let calls = Mutex(0)

    var loads: Int { calls.withLock { $0 } }

    func loadOrCreate() throws(SheetError) -> DeviceIdentity {
        calls.withLock { $0 += 1 }
        return try inner.loadOrCreate()
    }

    func reset() throws(SheetError) {
        try inner.reset()
    }
}

/// A relay socket that answers from a script and records what it was told.
///
/// Nothing in this file touches the network. The deployed relay is live, and a test that dialled
/// it would be a test whose result depends on somebody else's uptime.
private final class ScriptedSocket: RelaySocket {
    private struct State {
        var inbound: [String]
        var sent: [String] = []
        var connectedTo: URL?
        var closed = false
    }

    private let state: Mutex<State>

    init(inbound: [String] = []) {
        state = Mutex(State(inbound: inbound))
    }

    var sent: [String] { state.withLock { $0.sent } }
    var connectedTo: URL? { state.withLock { $0.connectedTo } }

    func connect(url: URL, headers: [String: String]) async throws(SheetError) {
        state.withLock { $0.connectedTo = url }
    }

    func send(_ text: String) async throws(SheetError) {
        state.withLock { $0.sent.append(text) }
    }

    func receive() async throws(SheetError) -> String {
        let next = state.withLock { current -> String? in
            current.inbound.isEmpty ? nil : current.inbound.removeFirst()
        }
        if let next { return next }
        // The script ran out: park instead of spinning. The client never cancels its reader, so
        // this suspends until the test process exits, which is what a quiet socket looks like.
        try? await Task.sleep(for: .seconds(3600))
        throw .internalInconsistency(detail: "the scripted socket was drained")
    }

    func close() async {
        state.withLock { $0.closed = true }
    }
}

// MARK: - Helpers

/// Polls until `condition` holds or the deadline passes. Returns what it last saw.
///
/// The service's status arrives over an `AsyncStream` fed by an actor, so "did the toggle land"
/// is a question with a delay in it and no callback to hang a `confirmation` on.
@MainActor
private func settles(within seconds: Double = 10, until condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A `UserDefaults` nobody else in the suite can write. The house rule is per-instance seams over
/// process-wide keys, and the master toggle is a process-wide key by definition — so the seam is
/// the domain it lives in.
private func scratchDefaults() throws -> (defaults: UserDefaults, teardown: @Sendable () -> Void) {
    let name = "com.quino.opensheets.cloud-share.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    return (defaults, { UserDefaults.standard.removePersistentDomain(forName: name) })
}

private func testConfiguration() throws -> CloudShareConfiguration {
    try #require(CloudShareConfiguration(relayOrigin: "https://relay.test"))
}

@MainActor
private func makeService(
    store: CountingShareLinkStore,
    identityStore: any DeviceIdentityStoring,
    defaults: UserDefaults,
    binary: URL? = URL(fileURLWithPath: "/nonexistent/opensheets-mcp"),
    socket: ScriptedSocket = ScriptedSocket()
) throws -> CloudShareService {
    CloudShareService(
        store: store,
        identityStore: identityStore,
        configuration: try testConfiguration(),
        bundledServerURL: { binary },
        makeSocket: { socket },
        defaults: defaults
    )
}

// MARK: - Suites

/// Everything Agent 7 owns, under one type so `swift test --filter CloudShareServiceTests` runs
/// all of it rather than the third of it that happens to share the name.
///
/// `.serialized` because these tests stand up real machinery — SQLite stores, a relay client, an
/// engine with its reaping task — and running twenty of them at once is a burst of concurrent
/// work rather than a test of anything. Serialised they cost about a tenth of a second in total,
/// and the whole file stops being a load generator for every other suite in the package.
@Suite("Cloud Share's app wiring", .serialized)
struct CloudShareServiceTests {
    @MainActor
    @Suite("Cloud Share off costs nothing")
    struct KillSwitch {
        /// The bar `OSFlagHandshake` set, met the same way: no object, so nothing to leak.
        @Test func theFlagWithholdsTheWholeService() throws {
            let app = AppModel(store: try Temp.store(), cloudShareForThisInstance: false)
            #expect(app.share == nil)
        }

        /// And on, it exists — otherwise the test above would pass with the feature deleted.
        @Test func thePerInstanceOverrideWinsOverTheFlag() throws {
            let app = AppModel(store: try Temp.store(), cloudShareForThisInstance: true)
            #expect(app.share != nil)
            // The owner's own switch is still off by default, so an existing service is a *quiet*
            // one: no relay socket was dialled by construction.
            #expect(app.share?.isEnabled == false)
            #expect(app.share?.status == .disabled)
        }

        /// The flag's default is the shipping default, and no test may need to set it.
        @Test func aFreshModelHasNoServiceWithoutAnybodySettingAnything() throws {
            #expect(Flags.cloudShareEnabled == false)
            let app = AppModel(store: try Temp.store())
            #expect(app.share == nil)
        }

        /// The second gate: the object exists, and still reads nothing.
        @Test func theToggleOffTouchesNeitherTheTableNorTheKeychain() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let identity = CountingIdentityStore()

            let service = try makeService(store: store, identityStore: identity, defaults: defaults)
            service.startIfEnabled()

            #expect(service.isEnabled == false)
            #expect(service.status == .disabled)
            #expect(store.counts == CountingShareLinkStore.Counts(reads: 0, writes: 0))
            #expect(identity.loads == 0, "no Keychain item is read while the feature is off")
            #expect(service.links.isEmpty)
        }

        /// A missing server binary is a reason, not a crash — and it is reported where the owner is
        /// already looking rather than thrown into a view body.
        @Test func startingWithoutTheEmbeddedBinaryGoesOfflineWithASentence() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults,
                binary: nil
            )

            service.setEnabled(true)

            #expect(service.status == .offline)
            #expect(service.statusDetail?.isEmpty == false)
            #expect(defaults.bool(forKey: CloudShareService.enabledDefaultsKey))
        }
    }

    @Suite("The status word is a total function of the engine's state")
    struct StatusMapping {
        /// The whole table, asserted without a socket — `AppModel.mcpStatus(for:)`'s reason for being
        /// static and pure.
        @Test(arguments: [
            (CloudShareEngine.Status.stopped, CloudShareStatus.disabled),
            (.connecting, .connecting),
            (.online, .online),
            (.offline(reason: "the relay refused the device credential"), .offline),
        ])
        func everyEngineStateHasAWord(engineStatus: CloudShareEngine.Status, expected: CloudShareStatus) {
            #expect(CloudShareService.status(for: engineStatus) == expected)
        }

        /// Four states in, four words out: no two engine states are shown the same way, so the pane
        /// cannot say "Online" about a socket that is merely trying.
        @Test func theFourStatesMapOntoFourDistinctWords() {
            let states: [CloudShareEngine.Status] = [.stopped, .connecting, .online, .offline(reason: "x")]
            let words = Set(states.map { CloudShareService.status(for: $0) })
            #expect(words.count == CloudShareStatus.allCases.count)
        }
    }

    @MainActor
    @Suite("The service is the settings pane's half of Cloud Share")
    struct Verbs {
        @Test func creatingALinkRecordsItAndHandsBackACopyableURL() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let identity = CountingIdentityStore()
            let service = try makeService(store: store, identityStore: identity, defaults: defaults)

            let record = try service.createLink(name: "  Ana  ", mode: .readWrite)

            #expect(record.name == "Ana", "the stored name is the trimmed one")
            #expect(record.mode == .readWrite)
            #expect(record.url.hasPrefix("https://relay.test/mcp/os1."))
            #expect(record.tokenHash.count == 64, "SHA-256, hex")
            #expect(store.records.count == 1)
            #expect(store.records.first == record)
            #expect(service.links.first == record, "the list the pane renders updates without a refresh")
            #expect(identity.loads == 1, "minting needs the device id, and that is the first Keychain read")
        }

        /// The URL's token is the one the hash is of — otherwise a link the owner pastes and a link
        /// the relay routes are two different links.
        @Test func theTokenInTheURLIsTheTokenThatWasHashed() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let service = try makeService(
                store: CountingShareLinkStore(),
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )

            let record = try service.createLink(name: "Priya")
            let raw = String(record.url.dropFirst("https://relay.test/mcp/".count))
            let token = try #require(ShareToken(rawValue: raw))
            #expect(token.hash == record.tokenHash)
        }

        @Test func aLinkWithoutANameIsRefused() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )

            #expect(throws: SheetError.self) { try service.createLink(name: "   ") }
            #expect(store.counts.writes == 0, "a refused create writes nothing")
        }

        @Test func aNameLongerThanTheLimitIsRefusedAndTheLimitItselfIsNot() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let service = try makeService(
                store: CountingShareLinkStore(),
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )

            let atTheLimit = String(repeating: "a", count: CloudShareService.maximumNameLength)
            #expect(throws: Never.self) { try service.createLink(name: atTheLimit) }
            #expect(throws: SheetError.self) { try service.createLink(name: atTheLimit + "a") }
        }

        @Test func revokingFlipsTheRecordAndTheRowTogether() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )
            let record = try service.createLink(name: "Ana")

            try service.revoke(id: record.id)

            #expect(store.records.first?.isActive == false, "the database is what the engine re-reads")
            #expect(service.links.first?.isActive == false, "and the row the owner is looking at agrees")
            #expect(store.records.first?.revokedAt != nil)
        }

        /// Revoking is what tells the relay. Proven end to end through a scripted socket, because
        /// "pushes the revocation" is a claim about a byte leaving the app, not about a method call.
        @Test func revokingTellsTheRelay() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let socket = ScriptedSocket(inbound: [#"{"type":"hello_ack","v":1}"#])
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults,
                socket: socket
            )

            service.setEnabled(true)
            let online = await settles { service.status == .online }
            #expect(online, "the scripted hello_ack lands")
            defer { service.setEnabled(false) }

            let record = try service.createLink(name: "Ana")
            try service.revoke(id: record.id)

            let sawRevocation = await settles {
                socket.sent.contains { line in
                    line.contains("link_upsert") && line.contains(record.tokenHash) && line.contains("\"revoked\":true")
                }
            }
            #expect(sawRevocation, "the relay is told, over the socket, with the hash and the flag")
            #expect(socket.connectedTo?.absoluteString == "wss://relay.test/agent")
        }

        /// Remove is the second half of a two-step, and the service refuses to let it be the first.
        @Test func removingAnActiveLinkIsRefused() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )
            let record = try service.createLink(name: "Ana")

            #expect(throws: SheetError.self) { try service.remove(id: record.id) }
            #expect(store.records.count == 1, "the row survives a refused remove")
        }

        @Test func removingARevokedLinkDeletesTheRow() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let store = CountingShareLinkStore()
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )
            let record = try service.createLink(name: "Ana")
            try service.revoke(id: record.id)

            try service.remove(id: record.id)

            #expect(store.records.isEmpty)
            #expect(service.links.isEmpty)
        }

        @Test func refreshReadsTheTableTheOwnerActuallyHas() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let seeded = ShareLinkRecord(name: "Seeded", url: "https://relay.test/mcp/os1.x.y", tokenHash: "abc")
            let store = CountingShareLinkStore(seed: [seeded])
            let service = try makeService(
                store: store,
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )

            #expect(service.links.isEmpty, "construction reads nothing")
            service.refresh()
            #expect(service.links == [seeded])
            #expect(store.counts.reads == 1)
        }

        /// The toggle is the owner's, and it is remembered where the pane's `@AppStorage` will read it.
        @Test func theToggleIsWrittenWhereTheSettingsPaneLooks() async throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            let service = try makeService(
                store: CountingShareLinkStore(),
                identityStore: CountingIdentityStore(),
                defaults: defaults
            )

            #expect(service.isEnabled == false, "default off")
            service.setEnabled(true)
            #expect(defaults.bool(forKey: "OSCloudShareEnabled"))
            #expect(service.isEnabled)
            service.setEnabled(false)
            #expect(defaults.bool(forKey: "OSCloudShareEnabled") == false)
            #expect(service.status == .disabled)
        }
    }

    @Suite("The relay origin is overridable for development")
    struct ConfigurationResolution {
        @Test func theCompiledOriginIsTheDefault() throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            #expect(CloudShareService.resolvedConfiguration(defaults: defaults) == .standard)
        }

        @Test func aWellFormedOverrideWins() throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            defaults.set("http://localhost:8787", forKey: "OSCloudRelayURL")

            let resolved = CloudShareService.resolvedConfiguration(defaults: defaults)
            #expect(resolved.relayOrigin.absoluteString == "http://localhost:8787")
            #expect(try resolved.agentURL().absoluteString == "ws://localhost:8787/agent")
        }

        /// A typo in `defaults write` must not be able to break the settings pane.
        @Test func anUnparseableOverrideIsIgnoredRatherThanFatal() throws {
            let (defaults, teardown) = try scratchDefaults()
            defer { teardown() }
            defaults.set("not a url", forKey: "OSCloudRelayURL")

            #expect(CloudShareService.resolvedConfiguration(defaults: defaults) == .standard)
        }
    }
}
