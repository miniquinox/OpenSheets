import Foundation
import GRDB
import SheetModel
@testable import SheetStore
import Testing

/// The `share_link` table, and the revocation semantics that make it a boundary.
///
/// A share link is a capability: whoever holds the URL can read every granted folder until the
/// owner takes it back. So the assertions that carry weight here are the ones about
/// *withdrawal* — that revoking is soft so the list can still show it, that revoking twice
/// keeps the first moment, and above all that a revoked link stops answering to its own token
/// hash — rather than the round-trip, which is merely a prerequisite.
@Suite struct ShareLinkStoreTests {
    /// A store and the scratch directory it lives in, held together because a
    /// `TemporaryDirectory` deletes itself the moment it deallocates.
    ///
    /// Typed as the protocol rather than the concrete class for two reasons: it is the seam the
    /// bridging service will actually hold, and this file imports GRDB, which has a `Database`
    /// of its own — a name that cannot be module-qualified here, because the `SheetStore` class
    /// shadows the `SheetStore` module.
    private struct Fixture {
        let scratch: TemporaryDirectory
        let database: any ShareLinkStoring
    }

    private func fixture(_ name: String) throws -> Fixture {
        let scratch = TemporaryDirectory(name)
        let database = try Database(url: scratch.url.appendingPathComponent("OpenSheets.sqlite"))
        return Fixture(scratch: scratch, database: database)
    }

    /// Whole seconds on purpose: GRDB stores dates to the millisecond, so a `Date()` with
    /// sub-millisecond precision would fail an equality assertion for a reason that has nothing
    /// to do with what is being tested.
    private static let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func link(
        name: String = "Ana",
        tokenHash: String,
        mode: ShareLinkMode = .readOnly,
        createdAt: Date = ShareLinkStoreTests.noon
    ) -> ShareLinkRecord {
        ShareLinkRecord(
            name: name,
            url: "https://relay.example.workers.dev/mcp/os1.dEvIcE.\(tokenHash)",
            tokenHash: tokenHash,
            mode: mode,
            createdAt: createdAt
        )
    }

    // MARK: - Round-trip

    @Test func everyFieldSurvivesTheRoundTrip() throws {
        let fixture = try fixture("share-link-round-trip")
        var record = link(name: "Ana", tokenHash: "hash-round-trip", mode: .readWrite)
        record.lastUsedAt = ShareLinkStoreTests.noon.addingTimeInterval(60)
        try fixture.database.insert(record)

        let stored = try fixture.database.record(id: record.id)
        #expect(stored == record)
        #expect(stored?.mode == .readWrite)
        #expect(stored?.isActive == true)
    }

    /// A link that has never been used says so, rather than pretending it was used at creation.
    @Test func aFreshLinkHasNoLastUsedMoment() throws {
        let fixture = try fixture("share-link-fresh")
        let record = link(tokenHash: "hash-fresh")
        try fixture.database.insert(record)

        #expect(try fixture.database.record(id: record.id)?.lastUsedAt == nil)
    }

    @Test func anUnknownIdIsAMiss() throws {
        let fixture = try fixture("share-link-unknown")
        try fixture.database.insert(link(tokenHash: "hash-unknown"))

        #expect(try fixture.database.record(id: ULID()) == nil)
    }

    // MARK: - Listing

    @Test func linksAreListedNewestFirst() throws {
        let fixture = try fixture("share-link-order")
        let older = link(
            name: "Older", tokenHash: "hash-older",
            createdAt: ShareLinkStoreTests.noon.addingTimeInterval(-3600)
        )
        let newer = link(name: "Newer", tokenHash: "hash-newer", createdAt: ShareLinkStoreTests.noon)
        try fixture.database.insert(older)
        try fixture.database.insert(newer)

        #expect(try fixture.database.all().map(\.name) == ["Newer", "Older"])
    }

    /// Two links created in the same millisecond must still come back in a *fixed* order.
    /// `ORDER BY created_at DESC` alone leaves the tie to SQLite's discretion — the bug
    /// `v2-recent-file-sequence` fixed for recents — so the id has to settle it.
    @Test func aCreatedAtTieIsBrokenDeterministically() throws {
        let fixture = try fixture("share-link-tie")
        let first = link(name: "First", tokenHash: "hash-tie-1")
        let second = link(name: "Second", tokenHash: "hash-tie-2")
        try fixture.database.insert(first)
        try fixture.database.insert(second)

        let once = try fixture.database.all().map(\.id)
        let twice = try fixture.database.all().map(\.id)
        #expect(once == twice)
        #expect(once == [first.id, second.id].sorted(by: >))
    }

    @Test func revokedLinksStayInTheList() throws {
        let fixture = try fixture("share-link-list-revoked")
        let record = link(tokenHash: "hash-listed-revoked")
        try fixture.database.insert(record)
        try fixture.database.revoke(id: record.id, at: ShareLinkStoreTests.noon)

        #expect(try fixture.database.all().count == 1)
        #expect(try fixture.database.all().first?.isActive == false)
    }

    // MARK: - Uniqueness

    /// The relay routes on the token hash. Two rows sharing one would be a link that revokes
    /// only half of itself, so the table refuses rather than the app remembering not to.
    @Test func aDuplicateTokenHashIsRefused() throws {
        let fixture = try fixture("share-link-duplicate")
        try fixture.database.insert(link(name: "Ana", tokenHash: "hash-collides"))

        let error = #expect(throws: SheetError.self) {
            try fixture.database.insert(link(name: "Bo", tokenHash: "hash-collides"))
        }
        guard let error, case let .databaseError(operation, _) = error else {
            Issue.record("expected a databaseError, got \(String(describing: error))")
            return
        }
        #expect(operation == "insert share_link")
        #expect(try fixture.database.all().count == 1)
    }

    // MARK: - Revocation

    @Test func revokingIsSoftSoTheRowSurvives() throws {
        let fixture = try fixture("share-link-revoke")
        let record = link(tokenHash: "hash-revoke")
        try fixture.database.insert(record)

        try fixture.database.revoke(id: record.id, at: ShareLinkStoreTests.noon)

        let stored = try fixture.database.record(id: record.id)
        #expect(stored?.revokedAt == ShareLinkStoreTests.noon)
        #expect(stored?.isActive == false)
        #expect(stored?.name == record.name)
        #expect(stored?.url == record.url)
    }

    /// A link stopped answering when it *first* stopped answering. A second revoke — a double
    /// click, or a replayed sync — must not rewrite that moment.
    @Test func revokingTwiceKeepsTheFirstMoment() throws {
        let fixture = try fixture("share-link-revoke-twice")
        let record = link(tokenHash: "hash-revoke-twice")
        try fixture.database.insert(record)

        try fixture.database.revoke(id: record.id, at: ShareLinkStoreTests.noon)
        try fixture.database.revoke(id: record.id, at: ShareLinkStoreTests.noon.addingTimeInterval(3600))

        #expect(try fixture.database.record(id: record.id)?.revokedAt == ShareLinkStoreTests.noon)
    }

    @Test func deletingRemovesTheRowEntirely() throws {
        let fixture = try fixture("share-link-delete")
        let record = link(tokenHash: "hash-delete")
        try fixture.database.insert(record)

        try fixture.database.delete(id: record.id)

        #expect(try fixture.database.record(id: record.id) == nil)
        #expect(try fixture.database.all().isEmpty)
    }

    // MARK: - Answering a request

    @Test func anActiveLinkAnswersToItsTokenHash() throws {
        let fixture = try fixture("share-link-active")
        let record = link(tokenHash: "hash-active")
        try fixture.database.insert(record)

        #expect(try fixture.database.activeRecord(tokenHash: "hash-active")?.id == record.id)
        #expect(try fixture.database.activeRecord(tokenHash: "hash-never-issued") == nil)
    }

    /// The authoritative half of "revocation is enforced twice": whatever the relay believes,
    /// the Mac stops recognising the token.
    @Test func aRevokedLinkNoLongerAnswersToItsTokenHash() throws {
        let fixture = try fixture("share-link-revoked-lookup")
        let record = link(tokenHash: "hash-revoked-lookup")
        try fixture.database.insert(record)
        #expect(try fixture.database.activeRecord(tokenHash: "hash-revoked-lookup") != nil)

        try fixture.database.revoke(id: record.id, at: ShareLinkStoreTests.noon)

        #expect(try fixture.database.activeRecord(tokenHash: "hash-revoked-lookup") == nil)
    }

    @Test func touchingLastUsedMovesOnlyThatColumn() throws {
        let fixture = try fixture("share-link-touch")
        let record = link(tokenHash: "hash-touch")
        try fixture.database.insert(record)
        let used = ShareLinkStoreTests.noon.addingTimeInterval(900)

        try fixture.database.touchLastUsed(id: record.id, at: used)

        let stored = try fixture.database.record(id: record.id)
        #expect(stored?.lastUsedAt == used)
        #expect(stored?.createdAt == record.createdAt)
        #expect(stored?.revokedAt == nil)
        #expect(stored?.tokenHash == record.tokenHash)
    }

    // MARK: - Migration

    /// The table arrives on a database that already ran v1 and v2 — an existing install, which
    /// is every install. Staged at v2 with a row in it, so "the migration ran" and "the data it
    /// ran over survived" are two separate assertions.
    @Test func theTableArrivesOnADatabaseThatAlreadyRanTheEarlierMigrations() throws {
        let scratch = TemporaryDirectory("share-link-migration")
        let url = scratch.url.appendingPathComponent("OpenSheets.sqlite")

        do {
            let staged = try DatabasePool(path: url.path(percentEncoded: false))
            try Database.migrator.migrate(staged, upTo: "v2-recent-file-sequence")
            try staged.write { db in
                try db.execute(
                    sql: "INSERT INTO preference (key, value) VALUES (?, ?)",
                    arguments: ["theme", "quiet-glass"]
                )
            }
            let tables = try staged.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            }
            #expect(!tables.contains("share_link"), "v2 must not already know about share_link")
            try staged.close()
        }

        let database = try Database(url: url)
        #expect(try database.preference("theme") == "quiet-glass")

        let record = link(tokenHash: "hash-after-migration")
        try database.insert(record)
        #expect(try database.all().map(\.id) == [record.id])
    }

    /// Reopening runs no migration twice, so an existing link list is not wiped by a restart.
    @Test func reopeningKeepsTheLinksThatWereAlreadyThere() throws {
        let scratch = TemporaryDirectory("share-link-reopen")
        let url = scratch.url.appendingPathComponent("OpenSheets.sqlite")
        let record = link(tokenHash: "hash-reopen")

        let first = try Database(url: url)
        try first.insert(record)

        let second = try Database(url: url)
        #expect(try second.record(id: record.id) == record)
    }
}
