import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// The workspace boundary (PLAN.md §7.2).
///
/// The MCP server is spawned by Claude Code and inherits the user's full file access. This is
/// the only thing between a prompt-injected agent and `~/.ssh`, so **a single escape is a P0**.
/// The escape suite below is written the way a suite like this has to be written: every case
/// asserts *denial*, and the positive cases are separate and few, so a bug that makes the
/// check vacuously permissive fails 25 tests rather than passing 25.
@Suite struct WorkspaceGrantsTests {
    /// Builds a grants object over a real granted directory, with the real deny-list.
    private func fixture(
        denyList: DenyList = .standard
    ) throws -> (grants: WorkspaceGrants, scratch: TemporaryDirectory, workspace: URL) {
        let scratch = TemporaryDirectory("grants")
        let workspace = scratch.directory("work")
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: denyList)
        try grants.grant(UserGrantAuthorization(unchecked: workspace))
        return (grants, scratch, workspace)
    }

    // MARK: - The escape suite

    /// Forty ways out of a granted folder, all denied.
    ///
    /// Every case is a real filesystem layout, not a string — `..` through a symlink behaves
    /// differently from `..` in a string, and a test that only checked strings would pass while
    /// the product leaked.
    @Test func escapeSuiteFindsNoEscapes() throws {
        let (grants, scratch, workspace) = try fixture()
        let outside = scratch.directory("outside")
        let secretFile = outside.appendingPathComponent("secrets.xlsx")
        try Data("secret".utf8).write(to: secretFile)

        // A sibling whose name merely starts with the granted folder's name. The classic
        // string-prefix bug: "/…/work-secret".hasPrefix("/…/work") is true.
        let workSecret = scratch.directory("work-secret")
        try Data("secret".utf8).write(to: workSecret.appendingPathComponent("payroll.xlsx"))
        let workDot = scratch.directory("work.old")
        let workSpace = scratch.directory("work more")

        // Symlinks planted *inside* the workspace, pointing out of it.
        let escapeDir = workspace.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escapeDir, withDestinationURL: outside)
        let escapeFile = workspace.appendingPathComponent("escape.xlsx")
        try FileManager.default.createSymbolicLink(at: escapeFile, withDestinationURL: secretFile)
        let escapeHome = workspace.appendingPathComponent("home")
        try FileManager.default.createSymbolicLink(
            at: escapeHome,
            withDestinationURL: URL(fileURLWithPath: NSHomeDirectory())
        )
        let escapeRoot = workspace.appendingPathComponent("root")
        try FileManager.default.createSymbolicLink(at: escapeRoot, withDestinationURL: URL(fileURLWithPath: "/"))
        // A symlink pointing back into the workspace — `..` applied *after* resolution walks
        // out of it. This is the case a lexical `standardized` gets wrong.
        let inward = workspace.appendingPathComponent("inward")
        try FileManager.default.createSymbolicLink(at: inward, withDestinationURL: workspace)
        // A relative symlink, which resolves against its own directory rather than the cwd.
        let relative = workspace.appendingPathComponent("relative")
        try FileManager.default.createSymbolicLink(
            atPath: relative.path(percentEncoded: false),
            withDestinationPath: "../outside"
        )
        // A symlink loop must be refused, not hung on.
        let loopA = workspace.appendingPathComponent("loopA")
        let loopB = workspace.appendingPathComponent("loopB")
        try FileManager.default.createSymbolicLink(
            atPath: loopA.path(percentEncoded: false),
            withDestinationPath: "loopB"
        )
        try FileManager.default.createSymbolicLink(
            atPath: loopB.path(percentEncoded: false),
            withDestinationPath: "loopA"
        )

        let workspacePath = workspace.path(percentEncoded: false)
        let scratchPath = scratch.url.path(percentEncoded: false)
        let home = NSHomeDirectory()

        let cases: [(name: String, path: String)] = [
            // -- traversal --------------------------------------------------------------
            ("plain ..", "\(workspacePath)/../outside/secrets.xlsx"),
            ("doubled ..", "\(workspacePath)/a/../../outside/secrets.xlsx"),
            ("many ..", "\(workspacePath)/../../../../../../../../etc/hosts"),
            (".. mixed with .", "\(workspacePath)/./../outside/./secrets.xlsx"),
            ("trailing ..", "\(workspacePath)/.."),
            ("// separators", "\(workspacePath)//..//outside//secrets.xlsx"),
            ("/./ noise", "\(scratchPath)/./outside/./secrets.xlsx"),
            (".. that lands on the parent", scratchPath),

            // -- symlinks ---------------------------------------------------------------
            ("symlinked directory out", "\(workspacePath)/escape/secrets.xlsx"),
            ("symlinked file out", "\(workspacePath)/escape.xlsx"),
            ("symlink to home", "\(workspacePath)/home/Documents"),
            ("symlink to root", "\(workspacePath)/root/etc/hosts"),
            ("symlink then ..", "\(workspacePath)/escape/../outside/secrets.xlsx"),
            ("inward symlink then ..", "\(workspacePath)/inward/../outside/secrets.xlsx"),
            ("relative symlink out", "\(workspacePath)/relative/secrets.xlsx"),
            ("symlink loop", "\(workspacePath)/loopA"),

            // -- neighbours that merely share a prefix ----------------------------------
            ("work-secret sibling", "\(scratchPath)/work-secret/payroll.xlsx"),
            ("work-secret itself", workSecret.path(percentEncoded: false)),
            ("work.old sibling", workDot.path(percentEncoded: false) + "/x.xlsx"),
            ("work more sibling", workSpace.path(percentEncoded: false) + "/x.xlsx"),
            ("workspace path with a suffix", workspacePath + "x/inner.xlsx"),

            // -- deny-list, which overrides the grant -----------------------------------
            ("~/.ssh", "\(home)/.ssh/id_rsa"),
            ("~/.aws", "\(home)/.aws/credentials"),
            ("~/.config/gh", "\(home)/.config/gh/hosts.yml"),
            ("~/Library/Keychains", "\(home)/Library/Keychains/login.keychain-db"),
            ("~/.claude.json", "\(home)/.claude.json"),
            ("tilde-expanded .ssh", "~/.ssh/known_hosts"),
            ("uppercase .SSH", "\(home)/.SSH/id_rsa"),
            ("*.pem inside the workspace", "\(workspacePath)/server.pem"),
            ("*.key inside the workspace", "\(workspacePath)/private.key"),
            (".env inside the workspace", "\(workspacePath)/.env"),
            (".env.local inside the workspace", "\(workspacePath)/.env.local"),
            ("uppercase .PEM inside the workspace", "\(workspacePath)/CERT.PEM"),
            ("symlink out of the workspace to a pem", "\(workspacePath)/escape/../work/deep.pem"),

            // -- encodings and normalisation --------------------------------------------
            ("percent-encoded traversal", "\(workspacePath)/%2e%2e/outside/secrets.xlsx"),
            ("file URL with traversal", "file://\(workspacePath)/../outside/secrets.xlsx"),
            ("NUL-ish separator noise", "\(workspacePath)/../outside//./secrets.xlsx"),

            // -- unrelated absolute paths ------------------------------------------------
            ("/etc/hosts", "/etc/hosts"),
            ("home directory", home),
            ("root", "/"),
        ]

        var escapes: [String] = []
        for testCase in cases where grants.isAllowed(testCase.path) {
            escapes.append("\(testCase.name): \(testCase.path)")
        }
        #expect(escapes.isEmpty, "GRANT ESCAPES (P0): \(escapes.joined(separator: " | "))")
        #expect(cases.count >= 25, "the escape suite must carry at least 25 cases, it has \(cases.count)")
    }

    /// The escapes have to be denied *for the right reason*, or a future refactor could keep
    /// the assertions green while removing the check that produces them.
    @Test func denialsCarryTheRightError() throws {
        let (grants, scratch, workspace) = try fixture()
        let outside = scratch.directory("outside")
        try Data("x".utf8).write(to: outside.appendingPathComponent("secrets.xlsx"))

        do {
            try grants.check("\(NSHomeDirectory())/.ssh/id_rsa")
            Issue.record("a deny-listed path was allowed")
        } catch {
            #expect(error.code == "grant.denyListed")
            #expect(error.message.contains("~/.ssh"), "the message must name the rule: \(error.message)")
            #expect(error.category == .security)
        }

        do {
            try grants.check("\(workspace.path(percentEncoded: false))/../outside/secrets.xlsx")
            Issue.record("traversal was allowed")
        } catch {
            #expect(error.code == "grant.outsideWorkspace")
            #expect(error.category == .security)
            #expect(error.recoverySuggestion?.contains("grant") == true)
        }
    }

    // MARK: - What must be allowed

    /// The boundary is worthless if it also denies the granted folder. These are the cases the
    /// product depends on working.
    @Test func allowsWhatItShould() throws {
        let (grants, _, workspace) = try fixture()
        let nested = workspace.appendingPathComponent("q4/reports")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let book = nested.appendingPathComponent("revenue.xlsx")
        try Data("x".utf8).write(to: book)

        #expect(grants.isAllowed(book))
        #expect(grants.isAllowed(workspace))
        #expect(grants.isAllowed(workspace.appendingPathComponent("does-not-exist-yet.xlsx")))
        #expect(grants.isAllowed("\(workspace.path(percentEncoded: false))/./q4/../q4/reports/revenue.xlsx"))
        #expect(grants.isAllowed("\(workspace.path(percentEncoded: false))//q4//reports//revenue.xlsx"))
        // A file inside the workspace reached through a symlink that is also inside it.
        let alias = workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        #expect(grants.isAllowed(alias.appendingPathComponent("revenue.xlsx")))
    }

    /// A hard link is a second name for the same inode, and the kernel cannot tell you where
    /// it "came from". So a hard link *inside* the workspace to a file outside it resolves to
    /// a path inside — and is allowed, because there is no resolution that says otherwise.
    ///
    /// This is worth an explicit test with an explicit note rather than a silent gap: creating
    /// one requires write access to the workspace *and* read access to the target, which means
    /// the attacker already had the file. The grant boundary does not claim to survive that,
    /// and pretending otherwise in a test would be worse than saying so here.
    @Test func hardLinkIntoTheWorkspaceIsAllowedAndThatIsUnderstood() throws {
        let (grants, scratch, workspace) = try fixture()
        let outside = scratch.directory("outside")
        let target = outside.appendingPathComponent("payroll.xlsx")
        try Data("secret".utf8).write(to: target)

        let link = workspace.appendingPathComponent("hardlink.xlsx")
        try FileManager.default.linkItem(at: target, to: link)

        // Allowed — and the path it is allowed *as* is inside the workspace, which is the
        // property that matters: nothing outside the workspace became addressable.
        #expect(grants.isAllowed(link))
        #expect(!grants.isAllowed(target))
        let canonical = try PathCanonicalizer.canonicalize(link)
        #expect(canonical.hasSuffix("/work/hardlink.xlsx"))
    }

    /// A hard link to a *deny-listed* file is still denied when it keeps the deny-listed name,
    /// which is the case the filename patterns are there for.
    @Test func hardLinkKeepingADeniedNameIsStillDenied() throws {
        let (grants, scratch, workspace) = try fixture()
        let outside = scratch.directory("outside")
        let target = outside.appendingPathComponent("key.pem")
        try Data("-----BEGIN".utf8).write(to: target)
        let link = workspace.appendingPathComponent("copy.pem")
        try FileManager.default.linkItem(at: target, to: link)
        #expect(!grants.isAllowed(link))
    }

    // MARK: - Grant lifecycle

    /// Revoking takes effect immediately.
    @Test func revokedGrantsStopWorking() throws {
        let scratch = TemporaryDirectory("revoke")
        let workspace = scratch.directory("work")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))
        let grants = WorkspaceGrants(mode: .app, storage: database, denyList: .empty)

        let grant = try grants.grant(UserGrantAuthorization(unchecked: workspace))
        #expect(grants.isAllowed(workspace.appendingPathComponent("x.xlsx")))
        try grants.revoke(id: try #require(grant.id))
        #expect(!grants.isAllowed(workspace.appendingPathComponent("x.xlsx")))
    }

    /// **No API path can create a grant except a user action in the app.**
    ///
    /// The MCP server's instance refuses outright. This is the second of the two independent
    /// barriers; the first is that ``UserGrantAuthorization``'s public initialiser is
    /// `@MainActor` and takes an `NSOpenPanel` result, which the server cannot form.
    @Test func mcpServerCannotCreateAGrant() throws {
        let scratch = TemporaryDirectory("mcp-mode")
        let workspace = scratch.directory("work")
        let grants = WorkspaceGrants(mode: .enforcementOnly, storage: nil, denyList: .empty)

        #expect(throws: SheetError.self) {
            try grants.grant(UserGrantAuthorization(unchecked: workspace))
        }
        #expect(grants.activeGrants().isEmpty)
        #expect(!grants.isAllowed(workspace))
    }

    /// A deny-listed folder cannot be granted in the first place, so the deny-list cannot be
    /// worked around by picking the folder in the panel.
    @Test func denyListedFolderCannotBeGranted() throws {
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .standard)
        #expect(throws: SheetError.self) {
            try grants.grant(UserGrantAuthorization(
                unchecked: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
            ))
        }
    }

    /// With nothing granted, nothing is allowed. A store that fails open would be worse than
    /// no store at all.
    @Test func noGrantsMeansNothingIsAllowed() throws {
        let scratch = TemporaryDirectory("empty")
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .empty)
        #expect(!grants.isAllowed(scratch.url))
        #expect(!grants.isAllowed(scratch.file("x.xlsx")))
    }

    /// Grants survive a restart: they come back out of the database, canonicalised as stored.
    @Test func grantsPersistAcrossInstances() throws {
        let scratch = TemporaryDirectory("persist")
        let workspace = scratch.directory("work")
        let databaseURL = scratch.url.appendingPathComponent("db.sqlite")

        let first = try Database(url: databaseURL)
        try WorkspaceGrants(mode: .app, storage: first, denyList: .empty)
            .grant(UserGrantAuthorization(unchecked: workspace))

        let second = try Database(url: databaseURL)
        let reloaded = WorkspaceGrants(mode: .enforcementOnly, storage: second, denyList: .empty)
        #expect(reloaded.isAllowed(workspace.appendingPathComponent("x.xlsx")))
    }

    // MARK: - Canonicalisation, on its own

    /// The property that makes the whole check work: `..` is applied to the *resolved* prefix.
    @Test func dotDotIsAppliedAfterSymlinkResolution() throws {
        let scratch = TemporaryDirectory("canon")
        let work = scratch.directory("work")
        let other = scratch.directory("other")
        try FileManager.default.createSymbolicLink(
            at: work.appendingPathComponent("link"),
            withDestinationURL: other
        )

        let canonical = try PathCanonicalizer.canonicalize("\(work.path(percentEncoded: false))/link/../target.xlsx")
        let expected = try PathCanonicalizer.canonicalize("\(scratch.url.path(percentEncoded: false))/target.xlsx")
        #expect(canonical == expected, "`..` was applied lexically instead of after resolution")
        #expect(!canonical.contains("/work/"))
    }

    /// Component comparison, in isolation from the filesystem.
    @Test func containmentComparesComponentsNotPrefixes() {
        let container = PathCanonicalizer.components("/Users/q/work")
        #expect(PathCanonicalizer.contains(
            container: container,
            path: PathCanonicalizer.components("/Users/q/work/book.xlsx"),
            caseInsensitive: false
        ))
        #expect(PathCanonicalizer.contains(container: container, path: container, caseInsensitive: false))
        #expect(!PathCanonicalizer.contains(
            container: container,
            path: PathCanonicalizer.components("/Users/q/work-secret/book.xlsx"),
            caseInsensitive: false
        ))
        #expect(!PathCanonicalizer.contains(
            container: container,
            path: PathCanonicalizer.components("/Users/q"),
            caseInsensitive: false
        ))
        #expect(!PathCanonicalizer.contains(
            container: container,
            path: PathCanonicalizer.components("/Users/q/WORK/book.xlsx"),
            caseInsensitive: false
        ))
        #expect(PathCanonicalizer.contains(
            container: container,
            path: PathCanonicalizer.components("/Users/q/WORK/book.xlsx"),
            caseInsensitive: true
        ))
    }

    /// A symlink loop terminates as a refusal.
    @Test func symlinkLoopIsRefusedNotHung() throws {
        let scratch = TemporaryDirectory("loop")
        let a = scratch.url.appendingPathComponent("a")
        let b = scratch.url.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(atPath: a.path(percentEncoded: false), withDestinationPath: "b")
        try FileManager.default.createSymbolicLink(atPath: b.path(percentEncoded: false), withDestinationPath: "a")

        #expect(throws: SheetError.self) {
            try PathCanonicalizer.canonicalize(a)
        }
    }

    /// Unicode: the same directory spelled NFC and NFD is the same directory, and the check
    /// must not deny one of them.
    @Test func unicodeNormalisationDoesNotSplitAPath() throws {
        let scratch = TemporaryDirectory("unicode")
        let composed = scratch.directory("café")
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .empty)
        try grants.grant(UserGrantAuthorization(unchecked: composed))

        let decomposed = scratch.url
            .appendingPathComponent("cafe\u{0301}")
            .appendingPathComponent("book.xlsx")
        #expect(grants.isAllowed(decomposed))
        // …and a *different* directory whose name merely looks similar is still denied.
        #expect(!grants.isAllowed(scratch.url.appendingPathComponent("cafe/book.xlsx")))
    }
}
