import Foundation
import SheetModel

/// What the holder of a share link may do (Cloud Share, D4).
///
/// The mode is enforced **on the Mac**, by spawning `opensheets-mcp` with a filtered tool
/// registry, so a read-only link's `tools/list` never mentions a write tool at all. The relay
/// neither knows nor enforces it. Storing the wire spelling rather than an ordinal is
/// deliberate: the string is what the database row and the app both carry, and a reordered
/// enum must not be able to silently change what an existing row means.
public enum ShareLinkMode: String, Sendable, CaseIterable {
    case readOnly = "read_only"
    case readWrite = "read_write"
}

/// A link the owner issued, and can revoke.
///
/// A share link is a **capability**: whoever holds the URL can read every granted folder, and
/// on a `readWrite` link edit it, until the owner revokes the link or quits the app. That is
/// what makes ``revokedAt`` and ``lastUsedAt`` the two fields the UI exists to show — a list of
/// capabilities nobody can audit or withdraw is not a security boundary.
public struct ShareLinkRecord: Sendable, Equatable, Identifiable {
    /// The primary key. A ULID rather than a UUID because it sorts by creation time, which is
    /// the order the list is shown in and a stable tiebreaker when two links share a timestamp.
    public var id: ULID
    /// The owner-facing label, e.g. "Ana". The only thing that makes "revoke the right one"
    /// possible three months later, which is why the app requires it.
    public var name: String
    /// The full capability URL, **in plaintext** (D7).
    ///
    /// Copy has to keep working long after creation, and there is nothing to reconstruct the
    /// URL from — ``tokenHash`` is one-way by design. The price of storing it is paid in
    /// ``DenyList/standard``: the directory this database lives in is denied to the tools, so a
    /// granted agent cannot read the links that grant it.
    public var url: String
    /// SHA-256 hex of the whole `os1.<deviceId>.<secret>` token — the only form the relay ever
    /// holds, and what an inbound request is matched against.
    public var tokenHash: String
    /// See ``ShareLinkMode``.
    public var mode: ShareLinkMode
    public var createdAt: Date
    /// Non-`nil` once revoked. Revoked links stay in the table so revocation reads as a fact
    /// rather than an absence — ``WorkspaceGrant/revokedAt``'s reasoning, for the same reason.
    public var revokedAt: Date?
    /// When a call last arrived on this link, or `nil` if none ever has. The owner's only
    /// evidence that a link they forgot about is still being used.
    public var lastUsedAt: Date?

    public init(
        id: ULID = ULID(),
        name: String,
        url: String,
        tokenHash: String,
        mode: ShareLinkMode = .readOnly,
        createdAt: Date = Date(),
        revokedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.tokenHash = tokenHash
        self.mode = mode
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.lastUsedAt = lastUsedAt
    }

    /// Whether this link still answers. Checked live per inbound request rather than cached:
    /// a revocation that only takes effect at the next restart is not a revocation.
    public var isActive: Bool { revokedAt == nil }
}

/// The persistence half of the share-link list.
///
/// Split out for ``WorkspaceGrantStoring``'s reason: the service that bridges frames can be
/// tested without a database, and the database can be swapped without touching the service.
/// Conforming methods `throws` untyped, matching the neighbouring storage protocols; the
/// ``Database`` conformance throws ``SheetError/databaseError(operation:underlying:)``.
public protocol ShareLinkStoring: Sendable {
    func insert(_ record: ShareLinkRecord) throws
    /// Every link, revoked ones included, newest first.
    func all() throws -> [ShareLinkRecord]
    func record(id: ULID) throws -> ShareLinkRecord?
    /// Soft: the row survives so the list can show what was revoked and when.
    func revoke(id: ULID, at date: Date) throws
    /// Hard, and only ever offered for an already-revoked link.
    func delete(id: ULID) throws
    func touchLastUsed(id: ULID, at date: Date) throws
    /// The active link with this token hash, or `nil` — the question every inbound request asks.
    func activeRecord(tokenHash: String) throws -> ShareLinkRecord?
}

extension SheetStore {
    /// The links this Mac has issued. See ``ShareLinkStoring``.
    ///
    /// Exposed the way ``grants`` is, and present in **both** modes, because the two modes
    /// reach it from opposite sides of the boundary: the app reads and writes it, and
    /// `opensheets-mcp` simply never asks. It cannot reach the table through the tools either —
    /// the directory holding this database is on ``DenyList/standard``.
    public var shareLinks: any ShareLinkStoring { database }
}
