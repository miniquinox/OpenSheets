import Foundation
import GlassUI
import SheetModel
import SheetShare
import SheetStore

/// Settings ▸ Cloud's half of Cloud Share: the list the owner sees, the four verbs they can press,
/// and the one status word above them.
///
/// # Where the line between this and the engine falls
///
/// ``SheetShare/CloudShareEngine`` owns sockets, subprocesses, and the live revocation check. It
/// is an actor with no opinion about SwiftUI, and it stays that way. This is the `@MainActor`
/// `@Observable` mirror the settings pane binds to: it holds `status` and `links` as *values a
/// view can read synchronously*, and it forwards the owner's presses down. Nothing here decides
/// anything about the boundary — refusing a revoked link happens in the engine, on every request,
/// against the database, and moving any part of that decision up here would put it behind a
/// cached array on the main actor, which is exactly the bug `AppModel.swift:447-449` exists to
/// forbid.
///
/// So: two rules, and they are the whole design.
///
/// 1. **Reads for display go through this object; reads that gate access do not.** ``links`` is a
///    snapshot for rendering a list. It is never consulted to decide whether a request may be
///    served.
/// 2. **The engine is constructed lazily and started explicitly.** Constructing this service
///    opens no socket, spawns no subprocess, and reads no Keychain item — see "What off costs".
///
/// # What off costs
///
/// Nothing, at two levels, and both are structural rather than asserted:
///
/// - **Flag off** (`OSFlagCloudShare`, default false): ``AppModel/share`` is `nil`. This object
///   is never constructed, so there is nothing to start and nothing to leak. That is the
///   `OSFlagHandshake` bar (`AppModel.swift:600-613`), met the same way.
/// - **Flag on, toggle off** (`OSCloudShareEnabled`, default false): the object exists so the
///   pane can render a switch, but ``startIfEnabled()`` returns before ``engine`` is built. No
///   Keychain read, no socket, no child process. The owner's link rows are still listed, because
///   listing rows the feature is not serving is the honest empty state — the alternative is a
///   pane that forgets the links it will resurrect the moment the switch flips.
///
/// `CloudShareServiceTests` pins both with a counting store, which is why ``ShareLinkStoring`` is
/// injected rather than reached for through ``SheetStore/shareLinks``.
@MainActor
@Observable
public final class CloudShareService {
    /// The user-facing master switch. Read fresh, like every flag in this app: a
    /// `defaults write` should take effect at the next check rather than the next launch.
    nonisolated public static let enabledDefaultsKey = "OSCloudShareEnabled"

    /// Points the app at a different relay — a `wrangler dev` instance, usually. Overrides the
    /// origin compiled into ``SheetShare/CloudShareConfiguration/standard``.
    nonisolated public static let relayURLDefaultsKey = "OSCloudRelayURL"

    /// The status word the pane shows, already mapped into GlassUI's vocabulary.
    public private(set) var status: CloudShareStatus = .disabled

    /// Why, when the status is ``GlassUI/CloudShareStatus/offline``. `nil` otherwise.
    ///
    /// The *word* is GlassUI's, because a state's name is identity. This is the sentence
    /// underneath it, and it is a fact rather than policy — the relay said the device credential
    /// was refused, or the socket never opened — so it travels up from the engine instead of
    /// being invented by whoever draws it. The App layer decides whether and how to show it.
    public private(set) var statusDetail: String?

    /// Every link this Mac has issued, newest first, revoked ones included.
    ///
    /// Empty until ``refresh()`` runs. Deliberately: building this object must not read the
    /// database, or "off costs nothing" would be true of the socket and false of the disk.
    public private(set) var links: [ShareLinkRecord] = []

    /// The last thing the engine said that was not a status change. Diagnostics only — never
    /// shown, never a token, and the reason a dead link is debuggable at all.
    public private(set) var lastDiagnostic: String?

    private let store: any ShareLinkStoring
    private let identityStore: any DeviceIdentityStoring
    private let configuration: CloudShareConfiguration
    private let engineConfiguration: CloudShareEngine.Configuration
    private let bundledServerURL: @Sendable () -> URL?
    private let makeSocket: @Sendable () -> any RelaySocket
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    private var engine: CloudShareEngine?
    private var consumer: Task<Void, Never>?

    /// - Parameters:
    ///   - store: the share-link table. ``SheetStore/shareLinks`` in the app; a counting fake in
    ///     the tests that prove nothing is read while the feature is off.
    ///   - identityStore: this Mac's device identity. Read on ``createLink(name:mode:)`` and on
    ///     ``startIfEnabled()``, and never at construction — the Keychain half of "off costs
    ///     nothing".
    ///   - configuration: where the relay is. Defaults to ``resolvedConfiguration(defaults:)``,
    ///     which honours `OSCloudRelayURL`.
    ///   - bundledServerURL: the embedded `opensheets-mcp`, resolved the way
    ///     ``ClaudeConnector/serverBinary`` resolves it and injected for the same reason: a test
    ///     process's main bundle is the test runner, so looking it up in here would make this
    ///     untestable and the app's behaviour unobservable.
    ///   - makeSocket: one socket per connection attempt. Fake in tests; never dialled until
    ///     ``startIfEnabled()``.
    public init(
        store: any ShareLinkStoring,
        identityStore: any DeviceIdentityStoring,
        configuration: CloudShareConfiguration? = nil,
        engineConfiguration: CloudShareEngine.Configuration = .default,
        bundledServerURL: @escaping @Sendable () -> URL? = CloudShareService.defaultServerURL,
        makeSocket: @escaping @Sendable () -> any RelaySocket = { URLSessionRelaySocket() },
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.identityStore = identityStore
        self.configuration = configuration ?? Self.resolvedConfiguration(defaults: defaults)
        self.engineConfiguration = engineConfiguration
        self.bundledServerURL = bundledServerURL
        self.makeSocket = makeSocket
        self.defaults = defaults
        self.now = now
    }

    /// The app's configuration: the real share-link table, the real Keychain, the real relay.
    ///
    /// The device identity is split across two stores by design (D6) — the id in the `preference`
    /// table so a database backup carries it, the secret in the Keychain so a backup does *not*.
    /// `SheetShare` cannot see `Database`, so it takes the two accessors as closures and this is
    /// where they are tied together. Both are fail-soft: a `preference` row that will not read
    /// looks like a Mac that has no identity yet, which mints a new one that then also fails to
    /// write — so a sick database produces a feature that does not work rather than one that
    /// silently rotates the owner's device id.
    public static func standard(store: SheetStore, defaults: UserDefaults = .standard) -> CloudShareService {
        let database = store.database
        return CloudShareService(
            store: store.shareLinks,
            identityStore: KeychainDeviceIdentityStore(
                readPreference: { key in try? database.preference(key) },
                writePreference: { key, value in try? database.setPreference(key, to: value) }
            ),
            defaults: defaults
        )
    }

    // MARK: - Configuration

    /// The relay origin this build talks to: `OSCloudRelayURL` when it is set and parses,
    /// otherwise the compiled-in default.
    ///
    /// An override that does not parse is ignored rather than fatal, and the compiled default
    /// answers instead. The alternative — refusing to build the service because a development
    /// default is malformed — turns a typo in `defaults write` into an app that cannot show its
    /// own settings pane.
    nonisolated public static func resolvedConfiguration(defaults: UserDefaults = .standard) -> CloudShareConfiguration {
        guard let text = defaults.string(forKey: relayURLDefaultsKey),
              let override = CloudShareConfiguration(relayOrigin: text)
        else { return .standard }
        return override
    }

    /// The embedded MCP server: the bundled copy when it is executable, else the documented
    /// `/usr/local/bin` install, else `nil`.
    ///
    /// The same resolution ``ClaudeConnector/serverBinary`` performs, and deliberately a copy of
    /// it rather than a call into it: the connector's copy answers "what would Connect register",
    /// which is a question about a config file, and this one answers "what would a link spawn".
    /// They agree today and there is no reason for one to constrain the other tomorrow.
    nonisolated public static let defaultServerURL: @Sendable () -> URL? = {
        let fileManager = FileManager.default
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp"),
           fileManager.isExecutableFile(atPath: bundled.path(percentEncoded: false)) {
            return bundled
        }
        let fallback = URL(fileURLWithPath: "/usr/local/bin/opensheets-mcp")
        if fileManager.isExecutableFile(atPath: fallback.path(percentEncoded: false)) { return fallback }
        return nil
    }

    // MARK: - Status

    /// The engine's state, in the word the pane shows. Pure, total, and static so the whole table
    /// can be asserted without a socket — ``AppModel/mcpStatus(for:)``'s idiom, for its reason.
    ///
    /// `.stopped` maps to `disabled` rather than to an "idle" of its own: a stopped engine is
    /// what the owner sees when the switch is off, and inventing a fifth word for a state the
    /// switch already explains would be a word nobody could act on.
    nonisolated public static func status(for engineStatus: CloudShareEngine.Status) -> CloudShareStatus {
        switch engineStatus {
        case .stopped: .disabled
        case .connecting: .connecting
        case .online: .online
        case .offline: .offline
        }
    }

    // MARK: - The master switch

    /// Whether the owner has switched Cloud Share on. Read fresh from `UserDefaults`, default
    /// **false** — the feature ships dark twice over (D10).
    public var isEnabled: Bool {
        defaults.object(forKey: Self.enabledDefaultsKey) as? Bool ?? false
    }

    /// Starts the engine if — and only if — the owner's switch is already on.
    ///
    /// Called once from ``AppModel/init(store:cloudShareForThisInstance:)``. This is the whole
    /// launch path: the service does not hang off a window, a scene, or `OpenActions`, because a
    /// share link has to keep answering while every window is closed. Calling it twice is a
    /// no-op, which matters because a `@State` model can be rebuilt.
    public func startIfEnabled() {
        guard isEnabled else { return }
        start()
    }

    /// Flips the master switch and acts on it.
    ///
    /// Non-throwing on purpose. Starting can fail — a Keychain that will not answer, a relay
    /// origin that is not a URL — and a switch that throws into a view body would have to be
    /// wrapped in an alert, which this app does not do (failures are inline). A failure to start
    /// lands where the owner is already looking: ``status`` goes ``GlassUI/CloudShareStatus/offline``
    /// and ``statusDetail`` says why.
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard engine == nil else { return }
        guard let binary = bundledServerURL() else {
            status = .offline
            statusDetail = "OpenSheets cannot find its own MCP server. Reinstall the app, then switch Cloud Share on again."
            return
        }

        let engine = CloudShareEngine(
            store: store,
            identityStore: identityStore,
            share: configuration,
            binaryURL: binary,
            configuration: engineConfiguration,
            makeSocket: makeSocket
        )
        self.engine = engine
        status = .connecting
        statusDetail = nil

        // Subscribe before starting: the engine yields its first status from inside `start()`,
        // and a consumer attached afterwards would race it. The stream buffers, so this is belt
        // and braces rather than load-bearing — but the ordering is free and the race is not.
        consumer = Task { [weak self] in
            for await event in engine.events {
                self?.apply(event)
            }
        }

        Task { [weak self] in
            do throws(SheetError) {
                try await engine.start()
            } catch {
                self?.failedToStart(error)
            }
        }
    }

    private func stop() {
        let engine = self.engine
        self.engine = nil
        consumer?.cancel()
        consumer = nil
        status = .disabled
        statusDetail = nil
        // Detached from the switch's turn: closing a socket and reaping children is not something
        // the owner should watch a toggle spin through, and the rows are already correct.
        Task { await engine?.stop() }
    }

    private func failedToStart(_ error: SheetError) {
        // The engine never started, so it will emit nothing; drop it rather than leave a corpse
        // that `start()`'s `engine == nil` guard would mistake for a running feature.
        engine = nil
        consumer?.cancel()
        consumer = nil
        status = .offline
        statusDetail = error.message
    }

    private func apply(_ event: CloudShareEngine.Event) {
        switch event {
        case let .status(engineStatus):
            status = Self.status(for: engineStatus)
            statusDetail = if case let .offline(reason) = engineStatus { reason } else { nil }
        case let .linkUsed(linkID, at):
            // The engine already wrote `last_used_at`; this keeps the visible row in step without
            // re-reading the table on every tool call.
            guard let index = links.firstIndex(where: { $0.id.rawValue == linkID }) else { return }
            links[index].lastUsedAt = at
        case let .linkRefused(linkID, reason):
            lastDiagnostic = "refused a request for link \(linkID): \(reason)"
        case let .diagnostic(detail):
            lastDiagnostic = detail
        }
    }

    // MARK: - The owner's four verbs

    /// Re-reads the link table. Called when the pane appears.
    ///
    /// Non-throwing and fail-soft, the `Persisted…` reads' idiom: a table that will not read
    /// leaves the last good list on screen and a sentence in ``lastDiagnostic``. There is nothing
    /// for the owner to do about a sick database from a settings pane, and blanking the list would
    /// tell them their links are gone when they are not.
    public func refresh() {
        do {
            links = try store.all()
        } catch {
            lastDiagnostic = "the share-link table could not be read: \(error)"
        }
    }

    /// Mints a link, records it, and tells the relay about it.
    ///
    /// The URL comes back so the App layer can put it on the clipboard — that is the only place
    /// the plaintext token is ever handled outside the database, and it is a deliberate one:
    /// "Create & Copy" is the entire feature from the owner's side.
    ///
    /// The relay push is fire-and-forget. Offline is not a failure here: the link exists in the
    /// database the moment this returns, the next `hello` carries the whole table, and a link the
    /// relay has not heard of yet simply 404s until it has.
    @discardableResult
    public func createLink(name: String, mode: ShareLinkMode = .readOnly) throws(SheetError) -> ShareLinkRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .invalidArgument(name: "name", reason: "name the link so you can revoke the right one later")
        }
        guard trimmed.count <= Self.maximumNameLength else {
            throw .invalidArgument(
                name: "name",
                reason: "a link name is at most \(Self.maximumNameLength) characters, and this one is \(trimmed.count)"
            )
        }

        let identity = try identityStore.loadOrCreate()
        let token = try ShareToken.mint(deviceID: identity.deviceID)
        let record = ShareLinkRecord(
            name: trimmed,
            url: configuration.linkURL(for: token),
            tokenHash: token.hash,
            mode: mode,
            createdAt: now()
        )
        try insert(record)

        links.insert(record, at: 0)
        push(record)
        return record
    }

    /// The longest name the owner may give a link. Long enough for "Ana's Q4 review contractor",
    /// short enough that a row stays one line.
    nonisolated public static let maximumNameLength = 64

    /// Revokes a link. The row stays; the capability does not.
    ///
    /// Two things happen, and only the second is load-bearing: the relay is told (fast path), and
    /// the row in the local database grows a `revoked_at` (authoritative path). The engine
    /// re-reads that row on every inbound request, so the link is dead the instant this returns
    /// even if the Mac is offline and the relay never hears about it. ``upsert(_:)`` also kills
    /// whatever subprocess the link had running, because a revoke that leaves a child alive is a
    /// capability the owner believes they withdrew.
    public func revoke(id: ULID) throws(SheetError) {
        let at = now()
        do {
            try store.revoke(id: id, at: at)
        } catch let error as SheetError {
            throw error
        } catch {
            throw .databaseError(operation: "revoke share link", underlying: "\(error)")
        }

        guard let index = links.firstIndex(where: { $0.id == id }) else {
            refresh()
            return
        }
        links[index].revokedAt = at
        push(links[index])
    }

    /// Deletes a revoked link's row.
    ///
    /// Refuses an active link, and the refusal is not paperwork. Deleting a live row would take
    /// the link off the owner's screen while the relay still held its hash — the engine would
    /// refuse it (a missing record fails closed), so nothing would actually be served, but the
    /// owner would have pressed something that reads as "revoke" and got "forget", with no way
    /// back to the second half. Revoke first; the list shows the difference.
    public func remove(id: ULID) throws(SheetError) {
        if let record = links.first(where: { $0.id == id }), record.isActive {
            throw .invalidArgument(
                name: "id",
                reason: "revoke a link before removing it, so the relay is told before the record is gone"
            )
        }
        do {
            try store.delete(id: id)
        } catch let error as SheetError {
            throw error
        } catch {
            throw .databaseError(operation: "delete share link", underlying: "\(error)")
        }
        links.removeAll { $0.id == id }
        Task { [engine] in await engine?.refreshLinks() }
    }

    private func insert(_ record: ShareLinkRecord) throws(SheetError) {
        do {
            try store.insert(record)
        } catch let error as SheetError {
            throw error
        } catch {
            throw .databaseError(operation: "insert share link", underlying: "\(error)")
        }
    }

    private func push(_ record: ShareLinkRecord) {
        Task { [engine] in await engine?.upsert(record) }
    }
}
