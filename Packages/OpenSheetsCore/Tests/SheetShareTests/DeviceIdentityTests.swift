import Foundation
import SheetModel
@testable import SheetShare
import Synchronization
import Testing

/// The `preference` table, as far as ``KeychainDeviceIdentityStore`` can tell.
///
/// A class because `Mutex` is non-copyable and the two closures the store takes have to see the
/// same rows the test does.
final class PreferenceDouble: Sendable {
    private let rows = Mutex<[String: String]>([:])

    init(seed: [String: String] = [:]) {
        rows.withLock { $0 = seed }
    }

    func value(for key: String) -> String? { rows.withLock { $0[key] } }

    func set(_ key: String, to value: String?) { rows.withLock { $0[key] = value } }

    /// `self` is captured rather than the lock: `Mutex` is non-copyable, so there is no copying
    /// it out into the closure, and the class is `Sendable` precisely so this is safe.
    var reader: @Sendable (String) -> String? {
        { [self] key in value(for: key) }
    }

    var writer: @Sendable (String, String?) -> Void {
        { [self] key, value in set(key, to: value) }
    }
}

/// Whether this machine will let an unsigned test binary keep a Keychain item.
///
/// # Why this is a probe rather than an assumption
///
/// `swift test` builds an unsigned binary, and the Keychain is the one dependency in `SheetShare`
/// that answers to the code signature rather than to the file system. On a developer's Mac the
/// file-based keychain accepts the item and the round trip below is a real test of the real
/// `SecItem` calls. In an environment without a login keychain — a stripped CI container, a
/// machine where the item is denied — the honest outcome is a *skipped* test, which shows up as
/// skipped, rather than an early `return` that reports a pass nobody earned.
///
/// The probe writes and deletes its own item under its own service name, so it cannot disturb
/// either the production identity or the round-trip tests.
enum KeychainProbe {
    static let isAvailable: Bool = {
        let preferences = PreferenceDouble()
        let store = KeychainDeviceIdentityStore(
            service: "com.quino.opensheets.cloud-share.tests.probe",
            readPreference: preferences.reader,
            writePreference: preferences.writer
        )
        do {
            _ = try store.loadOrCreate()
            try store.reset()
            return true
        } catch {
            return false
        }
    }()

    /// A service name no other run is using. The plan's test-only name plus a nonce: the name
    /// keeps the item obviously ours if a crash ever leaves one behind, and the nonce keeps a
    /// crashed run from poisoning the next one.
    static func uniqueService() -> String {
        "com.quino.opensheets.cloud-share.tests.\(UUID().uuidString)"
    }
}

/// **This Mac's identity: minted once, halved never.**
///
/// The behaviour worth testing here is not "it stores two strings" — it is the rule that an
/// identity is a pair or it is nothing. A device id that outlived its secret would present a new
/// credential for an already-registered id, and the relay would close that socket 4401 forever
/// with nothing on either side saying why. So the store mints both together and forgets both
/// together, and the test that seeds half a pair is the one that matters most.
///
/// `.serialized` because the Keychain cases talk to a machine-wide store.
@Suite("Device identity — a pair or nothing", .serialized)
struct DeviceIdentityTests {
    // MARK: - The in-memory store

    /// `loadOrCreate` is idempotent: the second call is the first call's answer.
    @Test func theInMemoryStoreReturnsTheSameIdentityEveryTime() throws {
        let store = InMemoryDeviceIdentityStore()
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()
        #expect(first == second)
        #expect(try store.loadOrCreate() == first)
    }

    /// A reset forgets both halves, and the next load registers a new device.
    @Test func resettingMintsAWholeNewDevice() throws {
        let store = InMemoryDeviceIdentityStore()
        let first = try store.loadOrCreate()
        try store.reset()
        let second = try store.loadOrCreate()
        #expect(first != second)
        #expect(first.deviceID != second.deviceID)
        #expect(first.secret != second.secret)
    }

    /// A seeded store hands back what it was seeded with, which is what lets the tests above
    /// this layer pin a device id.
    @Test func aSeededStoreReturnsWhatItWasSeededWith() throws {
        let seed = try #require(DeviceIdentity(
            deviceID: ShareTokenVectors.deviceID,
            secret: ShareTokenVectors.secret
        ))
        let store = InMemoryDeviceIdentityStore(seed: seed)
        #expect(try store.loadOrCreate() == seed)
    }

    // MARK: - The shapes

    /// A minted identity's device id is the same segment a token is built from, so
    /// `ShareToken.mint(deviceID:)` accepts it.
    @Test func aMintedIdentityIsTheSegmentATokenIsBuiltFrom() throws {
        let identity = try DeviceIdentity.mint()
        #expect(ShareToken.isBase64URL(identity.deviceID, count: ShareToken.deviceIDCharacterCount))
        #expect(ShareToken.isBase64URL(identity.secret, count: ShareToken.secretCharacterCount))
        let token = try ShareToken.mint(deviceID: identity.deviceID)
        #expect(token.deviceID == identity.deviceID)
        // The link secret and the device secret are different credentials. Sharing one would
        // mean a link holder could open the device's socket.
        #expect(token.secret != identity.secret)
    }

    /// The secret hash is the 64 lowercase hex characters the relay stores on first contact.
    @Test func theSecretHashIsWhatTheRelayStoresOnFirstContact() throws {
        let identity = try #require(DeviceIdentity(
            deviceID: ShareTokenVectors.deviceID,
            secret: ShareTokenVectors.secret
        ))
        #expect(identity.secretHash == ShareToken.sha256Hex(ShareTokenVectors.secret))
        #expect(identity.secretHash.count == 64)
        #expect(identity.secretHash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// Half a pair is not an identity, and neither is a truncated one.
    @Test func aMalformedPairIsNotAnIdentity() {
        #expect(DeviceIdentity(deviceID: "", secret: ShareTokenVectors.secret) == nil)
        #expect(DeviceIdentity(deviceID: ShareTokenVectors.deviceID, secret: "") == nil)
        #expect(DeviceIdentity(
            deviceID: ShareTokenVectors.deviceID,
            secret: String(ShareTokenVectors.secret.dropLast())
        ) == nil)
        #expect(DeviceIdentity(deviceID: ShareTokenVectors.secret, secret: ShareTokenVectors.secret) == nil)
    }

    /// Interpolating an identity prints the routing id and not the credential — the rule
    /// ``ShareToken/description`` follows, for the same reason.
    @Test func anIdentityNeverPrintsItsSecret() throws {
        let identity = try #require(DeviceIdentity(
            deviceID: ShareTokenVectors.deviceID,
            secret: ShareTokenVectors.secret
        ))
        let printed = "\(identity)"
        #expect(printed.contains(ShareTokenVectors.secret) == false)
        #expect(printed.contains(ShareTokenVectors.deviceID))
    }

    // MARK: - The preference row

    /// The row is the bytes somebody will read in `sqlite3`: sorted keys, ISO-8601 date, wire
    /// spelling of the id, and no credential anywhere in it.
    @Test func thePreferenceRowIsTheBytesSomebodyWillReadInSqlite3() {
        let record = PersistedCloudDevice(
            deviceID: ShareTokenVectors.deviceID,
            createdAt: Date(timeIntervalSince1970: 1_788_091_200)
        )
        #expect(record.encodedJSON() == #"{"createdAt":"2026-08-30T12:00:00Z","deviceId":"AAECAwQFBgcICQoLDA0ODw"}"#)
    }

    /// What it writes, it reads.
    @Test func thePreferenceRowRoundTrips() throws {
        let record = PersistedCloudDevice(
            deviceID: ShareTokenVectors.deviceID,
            createdAt: Date(timeIntervalSince1970: 1_788_091_200)
        )
        let json = try #require(record.encodedJSON())
        #expect(PersistedCloudDevice.decode(json) == record)
    }

    /// A missing or unreadable row is treated as absent rather than as an error.
    ///
    /// The house rule for this table: the caller substitutes a fresh identity, which is a
    /// working feature, where throwing would be a Cloud section that refuses to load because a
    /// preference got mangled.
    @Test(arguments: [nil, "", "null", "[]", #"{"deviceId":7}"#, #"{"createdAt":"never"}"#] as [String?])
    func aRowThatWillNotDecodeIsTreatedAsAbsent(raw: String?) {
        #expect(PersistedCloudDevice.decode(raw) == nil)
    }

    // MARK: - The Keychain store

    /// Create, load, and delete against the real `SecItem` API.
    ///
    /// The one test that proves the four `SecItem` calls line up: an item that is added but
    /// queried with a mismatched attribute set reads back as `errSecItemNotFound`, which would
    /// look exactly like "no identity yet" and mint a new device on every launch.
    @Test(.enabled(if: KeychainProbe.isAvailable))
    func theKeychainStoreRoundTripsAnIdentity() throws {
        let preferences = PreferenceDouble()
        let store = KeychainDeviceIdentityStore(
            service: KeychainProbe.uniqueService(),
            readPreference: preferences.reader,
            writePreference: preferences.writer
        )
        defer { try? store.reset() }

        let created = try store.loadOrCreate()
        #expect(preferences.value(for: PersistedCloudDevice.preferenceKey) != nil)

        let loaded = try store.loadOrCreate()
        #expect(loaded == created, "a second launch must not mint a second device")

        try store.reset()
        #expect(preferences.value(for: PersistedCloudDevice.preferenceKey) == nil)

        let afterReset = try store.loadOrCreate()
        #expect(afterReset != created)
    }

    /// The row on disk records the id that was actually minted.
    @Test(.enabled(if: KeychainProbe.isAvailable))
    func theStoredRowNamesTheDeviceThatWasMinted() throws {
        let preferences = PreferenceDouble()
        let store = KeychainDeviceIdentityStore(
            service: KeychainProbe.uniqueService(),
            readPreference: preferences.reader,
            writePreference: preferences.writer,
            now: { Date(timeIntervalSince1970: 1_788_091_200) }
        )
        defer { try? store.reset() }

        let identity = try store.loadOrCreate()
        let row = PersistedCloudDevice.decode(preferences.value(for: PersistedCloudDevice.preferenceKey))
        #expect(row?.deviceID == identity.deviceID)
        #expect(row?.createdAt == Date(timeIntervalSince1970: 1_788_091_200))
        // The credential is not in the row. It is the whole reason there are two stores.
        let raw = preferences.value(for: PersistedCloudDevice.preferenceKey) ?? ""
        #expect(raw.contains(identity.secret) == false)
    }

    /// A device id that outlived its secret is discarded, and a whole new pair is minted.
    ///
    /// This is the failure the type's note is about: keeping the id would produce a socket the
    /// relay closes 4401 on every attempt, forever, because the relay remembers the hash of a
    /// secret this Mac no longer has. Losing the id costs the existing links, which are dead
    /// anyway — their secrets went with it.
    @Test(.enabled(if: KeychainProbe.isAvailable))
    func aDeviceIdWithoutItsSecretIsDiscardedRatherThanReused() throws {
        let orphan = PersistedCloudDevice(
            deviceID: ShareTokenVectors.deviceID,
            createdAt: Date(timeIntervalSince1970: 1_788_091_200)
        )
        let json = try #require(orphan.encodedJSON())
        let preferences = PreferenceDouble(seed: [PersistedCloudDevice.preferenceKey: json])
        let store = KeychainDeviceIdentityStore(
            service: KeychainProbe.uniqueService(),
            readPreference: preferences.reader,
            writePreference: preferences.writer
        )
        defer { try? store.reset() }

        let identity = try store.loadOrCreate()
        #expect(identity.deviceID != ShareTokenVectors.deviceID)
        let row = PersistedCloudDevice.decode(preferences.value(for: PersistedCloudDevice.preferenceKey))
        #expect(row?.deviceID == identity.deviceID)
    }

    /// Two stores under two service names do not see each other's items.
    ///
    /// Which is what makes the test-only service name in the tests above a real isolation
    /// boundary rather than a naming convention: the production identity on the developer's Mac
    /// is untouched by running this suite.
    @Test(.enabled(if: KeychainProbe.isAvailable))
    func twoServicesDoNotSeeEachOthersIdentities() throws {
        let firstPreferences = PreferenceDouble()
        let first = KeychainDeviceIdentityStore(
            service: KeychainProbe.uniqueService(),
            readPreference: firstPreferences.reader,
            writePreference: firstPreferences.writer
        )
        defer { try? first.reset() }
        let secondPreferences = PreferenceDouble()
        let second = KeychainDeviceIdentityStore(
            service: KeychainProbe.uniqueService(),
            readPreference: secondPreferences.reader,
            writePreference: secondPreferences.writer
        )
        defer { try? second.reset() }

        #expect(try first.loadOrCreate() != second.loadOrCreate())
    }
}
