import Foundation
import SheetModel
import Synchronization

/// Paths no grant can reach (PLAN.md §7.2).
///
/// The deny-list exists because a grant is coarse — the user picks a folder — and some things
/// under a plausible folder must never be readable by an agent whatever the user clicked.
/// `~` is a folder somebody will grant.
///
/// **Matched case-insensitively, on purpose.** The grant check is case-*sensitive* on
/// case-sensitive volumes, because being loose there would widen a grant. Here the asymmetry
/// runs the other way: being loose only ever denies more, and `~/.SSH/id_rsa` on the default
/// case-insensitive boot volume is the same file as `~/.ssh/id_rsa`.
public struct DenyList: Sendable, Hashable {
    /// Directories, and everything inside them. Tilde-relative entries are expanded per user.
    public var directories: [String]
    /// Exact files.
    public var files: [String]
    /// Glob patterns matched against the **last path component** only.
    public var filenamePatterns: [String]

    public init(directories: [String], files: [String], filenamePatterns: [String]) {
        self.directories = directories
        self.files = files
        self.filenamePatterns = filenamePatterns
    }

    /// PLAN.md §7.2's list, plus the neighbours that hold the same class of secret. Adding to
    /// this list can only ever deny more, so erring towards more is free.
    public static let standard = DenyList(
        directories: [
            "~/.ssh", "~/.aws", "~/.config/gh", "~/Library/Keychains", "~/.gnupg",
            "~/.kube", "~/.docker", "~/Library/Cookies", "~/Library/Application Support/Google/Chrome",
            // Our own store: share-link URLs are kept there in plaintext, next to the snapshots
            // and the database, so an agent must not be able to read the links that grant it.
            "~/Library/Application Support/OpenSheets",
            "/etc/ssh", "/private/etc/ssh", "/var/db/shadow", "/private/var/db/shadow",
        ],
        files: [
            "~/.claude.json", "~/.netrc", "~/.npmrc", "~/.pypirc", "~/.git-credentials",
            "/etc/master.passwd", "/private/etc/master.passwd", "/etc/sudoers", "/private/etc/sudoers",
        ],
        filenamePatterns: ["*.pem", "*.key", "*.p12", "*.pfx", "*.keychain", "*.keychain-db", ".env*"]
    )

    /// Nothing denied. For tests that are checking grant containment on its own.
    public static let empty = DenyList(directories: [], files: [], filenamePatterns: [])

    /// This list, plus `directory` and everything inside it.
    ///
    /// ``standard`` names the store as a tilde-relative string, which is what keeps it a
    /// constant and is correct for every real install — and for the staged-`HOME` subprocess
    /// tests, where `~` is the staged home. A store configured to live somewhere else is
    /// covered by composing here rather than by editing the constant, which matters because
    /// composing can only ever deny *more*, and the list only bears changes in that direction.
    ///
    /// The path is canonicalised on the way in, so an entry given as `/var/…` still matches a
    /// checked path that resolves to `/private/var/…`.
    public func denying(directory: URL) -> DenyList {
        var composed = self
        composed.directories.append(
            (try? PathCanonicalizer.canonicalize(directory)) ?? directory.path(percentEncoded: false)
        )
        return composed
    }

    /// The rule that denies `canonicalPath`, or `nil`.
    ///
    /// Returning the rule rather than a bool is what lets ``SheetError/pathDenyListed(path:rule:)``
    /// say *which* rule fired — "it matched `*.pem`" is actionable, "denied" is not.
    func matchingRule(for canonicalPath: String) -> String? {
        let lowered = canonicalPath.precomposedStringWithCanonicalMapping.lowercased()
        let components = PathCanonicalizer.components(lowered)

        for directory in directories {
            let expanded = DenyList.expand(directory)
            guard !expanded.isEmpty else { continue }
            if PathCanonicalizer.contains(
                container: PathCanonicalizer.components(expanded),
                path: components,
                caseInsensitive: true
            ) { return directory }
        }
        for file in files {
            let expanded = DenyList.expand(file)
            guard !expanded.isEmpty else { continue }
            if PathCanonicalizer.components(expanded) == components { return file }
        }
        if let name = components.last {
            for pattern in filenamePatterns where DenyList.matches(pattern: pattern.lowercased(), name: name) {
                return pattern
            }
        }
        return nil
    }

    private static func expand(_ path: String) -> String {
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        return expanded.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// `fnmatch` semantics, which is what the pattern syntax in PLAN.md §7.2 means. Uses the
    /// libc implementation rather than a hand-rolled matcher: a subtly different glob in a
    /// security check is a hole with a plausible-looking test suite over it.
    private static func matches(pattern: String, name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}

/// Proof that a human chose a folder in the app.
///
/// PLAN.md §7.2's hard requirement is that *no argument or file content can widen a grant*. The
/// MCP server runs inside Claude Code with the user's full file access; if a tool argument
/// could mint a grant, the boundary would be decorative. So the only constructor is
/// `@MainActor` and takes a URL that came back from an `NSOpenPanel`:
///
/// - The MCP server never touches the main actor and never links AppKit, so it *cannot* form
///   one — this is a compile-time barrier, not a convention.
/// - `WorkspaceGrants.grant(_:)` takes nothing else, so an audit for "where can a grant come
///   from" is a search for this initialiser, and it has exactly one legitimate call site: the
///   app's folder picker.
///
/// ``WorkspaceGrants/Mode/enforcementOnly`` is the second, independent barrier — see there.
public struct UserGrantAuthorization: Sendable {
    /// The folder the user picked.
    public let url: URL
    /// Its security-scoped bookmark, so the grant survives a restart (PLAN.md §7.1).
    public let bookmark: Data?

    /// Mint one **only** from an `NSOpenPanel` result.
    ///
    /// - Parameter userSelectedDirectory: `panel.urls.first`, unmodified.
    @MainActor
    public init(userSelectedDirectory: URL, bookmark: Data? = nil) {
        url = userSelectedDirectory
        self.bookmark = bookmark
    }

    /// The same thing, for tests. Not `public`, so nothing outside this module can reach it —
    /// including `SheetMCP`.
    init(unchecked url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
    }
}

/// A folder the user granted access to.
public struct WorkspaceGrant: Sendable, Hashable, Codable, Identifiable {
    public var id: Int64?
    /// The canonical path. Stored canonical so a grant made through `/tmp` still matches a
    /// path arriving as `/private/tmp`.
    public var path: String
    /// Security-scoped bookmark data.
    public var bookmark: Data?
    public var grantedAt: Date
    /// Non-`nil` once revoked. Revoked grants are kept so the list can show what was revoked
    /// and when, and so revocation is a fact rather than an absence.
    public var revokedAt: Date?

    public init(
        id: Int64? = nil,
        path: String,
        bookmark: Data? = nil,
        grantedAt: Date = Date(),
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.grantedAt = grantedAt
        self.revokedAt = revokedAt
    }

    public var isActive: Bool { revokedAt == nil }
}

/// The boundary between an agent and the user's home directory (PLAN.md §7.2).
///
/// Every rule from the plan, in the order that makes them sound:
///
/// 1. **Canonicalise first.** ``PathCanonicalizer`` resolves symlinks and `..` together, so a
///    symlink out of the workspace is checked at its destination.
/// 2. **Deny-list before grants,** and it overrides them. A grant on `~` does not open `~/.ssh`.
/// 3. **Compare by path components,** never by string prefix, so `/Users/q/work-secret` is not
///    inside `/Users/q/work`.
/// 4. **Case handled per volume.** See ``PathCanonicalizer/volumeIsCaseSensitive(_:)``.
/// 5. **No path to a grant except a user action in the app.** See ``UserGrantAuthorization``.
///
/// The check is `nonisolated` and lock-protected rather than an actor, because `SheetMCP` calls
/// it on every tool invocation and an `await` on the security check is an `await` on every read.
public final class WorkspaceGrants: Sendable {
    /// What this instance is allowed to do.
    public enum Mode: Sendable, Hashable {
        /// The app. Can create and revoke grants.
        case app
        /// The MCP server. `grant(_:)` and `revoke(id:)` throw. A second, independent barrier
        /// to ``UserGrantAuthorization``'s: even if a future refactor made the token reachable,
        /// the server's own instance still refuses.
        case enforcementOnly
    }

    private struct State {
        var grants: [WorkspaceGrant] = []
        var loaded = false
    }

    /// See ``Mode``.
    public let mode: Mode
    /// See ``DenyList``.
    public let denyList: DenyList
    private let storage: (any WorkspaceGrantStoring)?
    private let state = Mutex(State())

    public init(mode: Mode, storage: (any WorkspaceGrantStoring)? = nil, denyList: DenyList = .standard) {
        self.mode = mode
        self.storage = storage
        self.denyList = denyList
    }

    /// Records a grant. The only way one is ever created.
    @discardableResult
    public func grant(_ authorization: UserGrantAuthorization) throws(SheetError) -> WorkspaceGrant {
        guard mode == .app else {
            throw SheetError.pathOutsideWorkspace(path: authorization.url.path(percentEncoded: false))
        }
        let canonical = try PathCanonicalizer.canonicalize(authorization.url)
        if let rule = denyList.matchingRule(for: canonical) {
            throw SheetError.pathDenyListed(path: canonical, rule: rule)
        }
        var grant = WorkspaceGrant(path: canonical, bookmark: authorization.bookmark)
        if let storage {
            do {
                grant = try storage.insert(grant)
            } catch let error as SheetError {
                throw error
            } catch {
                throw SheetError.databaseError(operation: "insert workspace_grant", underlying: "\(error)")
            }
        }
        state.withLock { state in
            state.grants.removeAll { $0.path == grant.path && $0.isActive }
            state.grants.append(grant)
            state.loaded = true
        }
        return grant
    }

    /// Revokes a grant. Paths under it stop being allowed immediately.
    public func revoke(id: Int64) throws(SheetError) {
        guard mode == .app else { throw SheetError.pathOutsideWorkspace(path: "\(id)") }
        do {
            try storage?.revoke(id: id, at: Date())
        } catch {
            throw SheetError.databaseError(operation: "revoke workspace_grant", underlying: "\(error)")
        }
        state.withLock { state in
            for index in state.grants.indices where state.grants[index].id == id {
                state.grants[index].revokedAt = Date()
            }
        }
    }

    /// Every grant, including revoked ones.
    public func allGrants() -> [WorkspaceGrant] {
        loadIfNeeded()
        return state.withLock { $0.grants }
    }

    /// Grants currently in force.
    public func activeGrants() -> [WorkspaceGrant] {
        allGrants().filter(\.isActive)
    }

    /// Throws unless `url` may be read or written.
    ///
    /// The error is deliberately specific: ``SheetError/pathDenyListed(path:rule:)`` names the
    /// rule, ``SheetError/pathOutsideWorkspace(path:)`` carries the recovery suggestion telling
    /// the user to grant the folder **in the app**, which is the only place it can be done.
    public func check(_ url: URL) throws(SheetError) {
        try check(url.path(percentEncoded: false))
    }

    /// See ``check(_:)``.
    public func check(_ path: String) throws(SheetError) {
        // A `%2e%2e` in a path is a literal directory name to the kernel, so on its own it
        // reaches nothing. It becomes an escape the moment anything downstream percent-decodes
        // — a tool argument round-tripped through a URL, say — and that decode would happen
        // *after* this check. So the decoded form has to pass too. Fail-closed: both spellings
        // must be inside a grant, or neither is.
        if let decoded = path.removingPercentEncoding, decoded != path {
            try checkResolved(decoded)
        }
        try checkResolved(path)
    }

    private func checkResolved(_ path: String) throws(SheetError) {
        let canonical = try PathCanonicalizer.canonicalize(path)

        // The deny-list is applied to the canonical path *and* to the path as written. The
        // second pass costs nothing and closes the case where a component that does not exist
        // yet — a file about to be created — would not be resolved into view.
        if let rule = denyList.matchingRule(for: canonical) {
            throw SheetError.pathDenyListed(path: canonical, rule: rule)
        }
        let literal = (path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path)
        if let rule = denyList.matchingRule(for: (literal as NSString).standardizingPath) {
            throw SheetError.pathDenyListed(path: canonical, rule: rule)
        }

        let components = PathCanonicalizer.components(canonical)
        loadIfNeeded()
        let grants = state.withLock { $0.grants.filter(\.isActive) }
        for grant in grants {
            // Canonicalise the grant at check time too: the folder may have become a symlink,
            // or been replaced, since the user picked it.
            let container = (try? PathCanonicalizer.canonicalize(grant.path)) ?? grant.path
            let caseInsensitive = !PathCanonicalizer.volumeIsCaseSensitive(container)
            if PathCanonicalizer.contains(
                container: PathCanonicalizer.components(container),
                path: components,
                caseInsensitive: caseInsensitive
            ) { return }
        }
        throw SheetError.pathOutsideWorkspace(path: canonical)
    }

    /// Whether `url` is allowed. See ``check(_:)`` for why it failed.
    public func isAllowed(_ url: URL) -> Bool {
        (try? check(url)) != nil
    }

    /// See ``isAllowed(_:)``.
    public func isAllowed(_ path: String) -> Bool {
        (try? check(path)) != nil
    }

    /// Loads grants from storage on first use. Failing to load denies everything, which is the
    /// only safe direction: a database that will not open must not become an open door.
    private func loadIfNeeded() {
        let needed = state.withLock { !$0.loaded }
        guard needed else { return }
        let loaded = (try? storage?.allGrants()) ?? []
        state.withLock { state in
            guard !state.loaded else { return }
            state.grants = loaded
            state.loaded = true
        }
    }

    /// Drops the cache so the next check re-reads storage. For the MCP server, which sees
    /// grants the app created after it started.
    public func invalidateCache() {
        state.withLock { $0.loaded = false }
    }
}

/// The persistence half of ``WorkspaceGrants``.
public protocol WorkspaceGrantStoring: Sendable {
    func insert(_ grant: WorkspaceGrant) throws -> WorkspaceGrant
    func revoke(id: Int64, at date: Date) throws
    func allGrants() throws -> [WorkspaceGrant]
}
