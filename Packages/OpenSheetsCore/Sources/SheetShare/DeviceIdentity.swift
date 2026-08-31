import Foundation
import SheetModel
import Security
import Synchronization

/// This Mac, as the relay knows it: a routing id and the secret that proves the socket belongs
/// to whoever registered that id.
///
/// # Why the two halves must be minted and lost together
///
/// The relay learns a device on first contact and remembers `SHA-256(secret)` forever after
/// (trust on first use — the id is 128 random bits, so nobody can register yours before you do).
/// That makes the pair indivisible in a way that is easy to get wrong: if the id survived in the
/// `preference` row while the secret vanished from the Keychain, the next connection would
/// present a *new* secret for an *already registered* id, and the relay would correctly close it
/// 4401 — forever, with no way for the owner to see why. So ``DeviceIdentityStoring`` treats a
/// half-present identity as no identity at all and mints a fresh pair, which registers cleanly
/// under a new id. The cost is that links issued before the loss stop working, and that is the
/// honest outcome: their secrets are gone.
public struct DeviceIdentity: Sendable, Equatable, CustomStringConvertible {
    /// 22 base64url characters — the same segment that appears in every token this device mints,
    /// and the name of the relay's Durable Object.
    public let deviceID: String

    /// 43 base64url characters, sent as the socket's bearer credential. Never leaves the Keychain
    /// except to open a connection.
    public let secret: String

    /// What the relay stores. Exposed for logging and for tests that assert the relay's view;
    /// the app never needs to compute it in production.
    public var secretHash: String { ShareToken.sha256Hex(secret) }

    /// Redacted, for the reason ``ShareToken/description`` is.
    public var description: String { "DeviceIdentity(\(deviceID), secret: <redacted>)" }

    /// Accepts only a well-formed pair, so a truncated Keychain read cannot become an identity
    /// that fails authentication for reasons nobody can trace.
    public init?(deviceID: String, secret: String) {
        guard ShareToken.isBase64URL(deviceID, count: ShareToken.deviceIDCharacterCount),
              ShareToken.isBase64URL(secret, count: ShareToken.secretCharacterCount)
        else { return nil }
        self.deviceID = deviceID
        self.secret = secret
    }

    /// A fresh pair from the system CSPRNG.
    public static func mint() throws(SheetError) -> DeviceIdentity {
        let deviceID = try ShareToken.newDeviceID()
        let secret = ShareToken.base64URL(try ShareToken.randomBytes(ShareToken.secretByteCount))
        guard let identity = DeviceIdentity(deviceID: deviceID, secret: secret) else {
            throw .internalInconsistency(detail: "minted a device identity that does not match its own format")
        }
        return identity
    }

    /// The two headers wire contract A names on the agent socket. Written down once so the
    /// client and any test double spell them the same way.
    public enum Header {
        public static let authorization = "Authorization"
        public static let device = "X-OpenSheets-Device"

        public static func bearer(_ secret: String) -> String { "Bearer \(secret)" }
    }
}

/// The device id as it sits in the `preference` table.
///
/// # Why the id is here and the secret is not
///
/// The `preference` table is a SQLite row in a file the owner can read, and the documented way
/// to inspect this feature is `sqlite3 … "SELECT value FROM preference WHERE key='cloud.device'"`.
/// A routing identifier is fine there — it is a name, not a capability. The secret is a
/// credential, so it lives in the Keychain, which is the one store on the machine that is
/// encrypted at rest and access-controlled per application.
///
/// The dates are ISO-8601 rather than `JSONEncoder`'s default seconds-since-2001 for the same
/// reason the keys are sorted: somebody is going to read this row in a terminal.
public struct PersistedCloudDevice: Sendable, Equatable, Codable {
    /// The `preference` key. Namespaced `cloud.` beside `workspace.explorer` and
    /// `workspace.tabs`.
    public static let preferenceKey = "cloud.device"

    public var deviceID: String
    public var createdAt: Date

    public init(deviceID: String, createdAt: Date) {
        self.deviceID = deviceID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case createdAt
    }

    /// The exact bytes of the row, or `nil` if the encode failed.
    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Fail-soft, like every other reader of this table: a row that will not decode is treated
    /// as a row that is not there, and the caller mints a new identity. See
    /// `PersistedWorkspaceTree.read(from:)` for why that is the right shape of failure here.
    public static func decode(_ raw: String?) -> PersistedCloudDevice? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedCloudDevice.self, from: data)
    }
}

/// Where this Mac's identity comes from.
///
/// A protocol rather than a concrete type because the Keychain is the one dependency in
/// `SheetShare` that cannot be exercised freely: it is a machine-wide store with its own
/// permission model, and a test that races another test over the same item is a test that fails
/// on somebody else's laptop. Everything above this protocol takes the in-memory store.
public protocol DeviceIdentityStoring: Sendable {
    /// The stored identity, or a freshly minted and persisted one. Idempotent: two calls with no
    /// ``reset()`` between them return the same pair.
    func loadOrCreate() throws(SheetError) -> DeviceIdentity

    /// Forgets the identity — both halves, per the type note on ``DeviceIdentity``. The next
    /// ``loadOrCreate()`` registers a new device with the relay, and every link minted under the
    /// old id is dead.
    func reset() throws(SheetError)
}

/// A store that keeps the identity in memory. For tests, and for any caller that wants the
/// minting logic without touching the machine.
public final class InMemoryDeviceIdentityStore: DeviceIdentityStoring {
    private let stored = Mutex<DeviceIdentity?>(nil)

    public init(seed: DeviceIdentity? = nil) {
        stored.withLock { $0 = seed }
    }

    public func loadOrCreate() throws(SheetError) -> DeviceIdentity {
        if let existing = stored.withLock({ $0 }) { return existing }
        let minted = try DeviceIdentity.mint()
        // Last write wins under contention rather than first: two racing callers both get a
        // valid identity, and the one that lands is the one the next reader sees. The production
        // store is called once at service start, so this only matters to tests.
        return stored.withLock { slot in
            slot = slot ?? minted
            return slot ?? minted
        }
    }

    public func reset() throws(SheetError) {
        stored.withLock { $0 = nil }
    }
}

/// The real store: id in the `preference` table, secret in the macOS Keychain.
///
/// # Why the preference row arrives as two closures
///
/// `SheetShare` does not import `Database`. The `preference` table's payload structs live in
/// `SheetStore` because the app *and* the MCP server read them; this row is read by the app
/// alone, so putting a `Database` dependency in a leaf target to reach one string would buy a
/// coupling for nothing. The caller passes the two accessors it already has. Writing `nil`
/// deletes the row.
///
/// # Which keychain
///
/// The file-based keychain, not the data-protection one: the data-protection keychain requires
/// a `keychain-access-groups` entitlement, which an unsigned build — including the one
/// `swift test` produces — does not have, and a store that only works in a signed app is a store
/// nothing can test. Items are marked `AfterFirstUnlock` so a reconnect after a reboot does not
/// wait for the user to visit Settings.
public struct KeychainDeviceIdentityStore: DeviceIdentityStoring {
    /// The production service name. Tests pass their own; see ``DeviceIdentityTests``.
    public static let standardService = "com.quino.opensheets.cloud-share"

    /// One item per service — this Mac has one identity.
    public static let account = "device"

    private let service: String
    private let readPreference: @Sendable (String) -> String?
    private let writePreference: @Sendable (String, String?) -> Void
    private let now: @Sendable () -> Date

    public init(
        service: String = KeychainDeviceIdentityStore.standardService,
        readPreference: @escaping @Sendable (String) -> String?,
        writePreference: @escaping @Sendable (String, String?) -> Void,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.readPreference = readPreference
        self.writePreference = writePreference
        self.now = now
    }

    public func loadOrCreate() throws(SheetError) -> DeviceIdentity {
        let stored = PersistedCloudDevice.decode(readPreference(PersistedCloudDevice.preferenceKey))
        if let stored, let secret = try readSecret(), let identity = DeviceIdentity(
            deviceID: stored.deviceID,
            secret: secret
        ) {
            return identity
        }
        // Either half missing, or a pair that no longer parses: mint both. See the note on
        // ``DeviceIdentity`` for why half an identity is worse than none.
        let identity = try DeviceIdentity.mint()
        try writeSecret(identity.secret)
        let record = PersistedCloudDevice(deviceID: identity.deviceID, createdAt: now())
        guard let json = record.encodedJSON() else {
            throw .internalInconsistency(detail: "the cloud device row would not encode")
        }
        writePreference(PersistedCloudDevice.preferenceKey, json)
        return identity
    }

    public func reset() throws(SheetError) {
        try deleteSecret()
        writePreference(PersistedCloudDevice.preferenceKey, nil)
    }

    // MARK: - Keychain

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private func readSecret() throws(SheetError) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw readFailure(status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            // A present-but-unreadable item is treated as absent, which sends the caller down
            // the mint-a-new-pair path rather than leaving the feature permanently broken.
            return nil
        }
        return text
    }

    private func writeSecret(_ secret: String) throws(SheetError) {
        try deleteSecret()
        var query = baseQuery
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw writeFailure(status) }
    }

    private func deleteSecret() throws(SheetError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw writeFailure(status) }
    }

    /// # Why a Keychain failure is a file error
    ///
    /// `SheetError` is frozen — PLAN.md §8 has one error type and adding a case is a documented
    /// request, not a decision made in passing. Of the cases that exist, the two IO ones carry
    /// exactly the right shape (a thing that could not be read or written, plus the underlying
    /// reason) and land in the `io` category, which is how the settings pane should present
    /// "a system store refused us". The path reads as what it is — a keychain item, named — so
    /// the message stays true: "Keychain item com.quino.opensheets.cloud-share/device could not
    /// be read: OSStatus -25308 (interaction not allowed)".
    private func readFailure(_ status: OSStatus) -> SheetError {
        .fileNotReadable(path: itemDescription, underlying: Self.describe(status))
    }

    private func writeFailure(_ status: OSStatus) -> SheetError {
        .fileNotWritable(path: itemDescription, underlying: Self.describe(status))
    }

    /// Names the service this store was actually built with, so a test failure says which item
    /// it was talking to.
    private var itemDescription: String {
        "Keychain item \(service)/\(Self.account)"
    }

    private static func describe(_ status: OSStatus) -> String {
        guard let message = SecCopyErrorMessageString(status, nil) as String? else {
            return "OSStatus \(status)"
        }
        return "OSStatus \(status) (\(message))"
    }
}
