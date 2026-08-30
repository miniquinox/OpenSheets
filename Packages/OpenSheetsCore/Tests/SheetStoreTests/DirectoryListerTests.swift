import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// **The lister, tested as a boundary first and a file browser second.**
///
/// ``WorkspaceGrantsTests`` proves the grant check denies forty-three escapes. That is necessary
/// and not sufficient: what ships is a thing that *enumerates directories*, and the question this
/// suite answers is whether every route through it reaches that check and nothing routes around
/// it. So the escape cases come first, and they are asserted on the error code rather than on the
/// mere fact of a throw — a refactor that denied everything for the wrong reason would otherwise
/// stay green.
///
/// `.serialized` because every case builds a real tree on disk. Real layouts, not strings: a
/// symlink out of a folder behaves differently from `..` in a path, and a suite that only checked
/// strings would pass while the product leaked.
@Suite(.serialized) struct DirectoryListerTests {
    /// What the app actually asks for — `WorkbookIOAdapters.workbookExtensions` narrowed to the
    /// two spellings every case here needs.
    private let readable: Set<String> = ["xlsx", "csv"]

    /// A lister over one granted temp folder, with the **real** deny-list.
    ///
    /// `storage: nil` keeps the grants in memory, which is the idiom ``WorkspaceGrantsTests``
    /// already uses: a database would add a failure mode that has nothing to do with listing.
    private struct Fixture {
        var lister: DirectoryLister
        var scratch: TemporaryDirectory
        var workspace: URL

        /// The path as written — under `/var/folders/…`, which is a symlink. Passing this in and
        /// getting `/private/var/folders/…` back is how these tests see canonicalisation happen.
        var workspacePath: String { workspace.path(percentEncoded: false) }
        var canonicalWorkspacePath: String {
            workspace.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        }
    }

    private func makeFixture() throws -> Fixture {
        let scratch = TemporaryDirectory("lister")
        let workspace = scratch.directory("work")
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .standard)
        try grants.grant(UserGrantAuthorization(unchecked: workspace))
        return Fixture(lister: DirectoryLister(grants: grants), scratch: scratch, workspace: workspace)
    }

    @discardableResult
    private func write(_ name: String, in directory: URL, contents: String = "seed") throws -> URL {
        let target = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: target)
        return target
    }

    @discardableResult
    private func makeDirectory(_ name: String, in directory: URL) throws -> URL {
        let target = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    // MARK: - The boundary

    /// A folder no grant covers is refused, and refused for the right reason.
    @Test func refusesADirectoryOutsideEveryGrant() throws {
        let fixture = try makeFixture()

        do {
            _ = try fixture.lister.list("/etc", fileExtensions: readable, limit: DirectoryLimits.pageSize)
            Issue.record("an ungranted directory was listed")
        } catch {
            #expect(error.code == "grant.outsideWorkspace")
            #expect(error.category == .security)
        }

        // The sibling whose name merely starts with the granted folder's. The classic prefix bug:
        // `"/…/work-secret".hasPrefix("/…/work")` is true, and this must still be denied.
        let sibling = fixture.scratch.directory("work-secret")
        #expect(throws: SheetError.self) {
            try fixture.lister.list(
                sibling.path(percentEncoded: false),
                fileExtensions: readable,
                limit: DirectoryLimits.pageSize
            )
        }
    }

    /// Inside the grant is not enough: the deny-list overrides it.
    @Test func refusesADenyListedDirectoryInsideTheGrant() throws {
        let fixture = try makeFixture()
        // `.env*` matches the last path component, so a *folder* named `.env` is denied exactly
        // as a file called `.env.local` is. Nothing under it is reachable either.
        let denied = try makeDirectory(".env", in: fixture.workspace)
        try write("budget.xlsx", in: denied)

        do {
            _ = try fixture.lister.list(
                denied.path(percentEncoded: false),
                fileExtensions: readable,
                limit: DirectoryLimits.pageSize
            )
            Issue.record("a deny-listed directory was listed")
        } catch {
            #expect(error.code == "grant.denyListed")
            #expect(error.message.contains(".env"), "the message must name the rule: \(error.message)")
            #expect(error.category == .security)
        }
    }

    /// A symlink out of the workspace is listed under its own name but identified by its
    /// destination — so descending into it is checked against `/etc` and refused.
    ///
    /// This is the case that makes the canonical-path rule load-bearing rather than tidy. A
    /// lister that reported `<workspace>/etclink` would hand the layer above a path that passes
    /// the grant check and reads somebody else's `/etc`.
    @Test func doesNotFollowASymlinkOutOfTheWorkspace() throws {
        let fixture = try makeFixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("etclink"),
            withDestinationURL: URL(fileURLWithPath: "/etc")
        )

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )
        let entry = try #require(listing.entries.first { $0.name == "etclink" })
        // Named for the link, identified by the destination. `/etc` and not `/private/etc`:
        // `resolvingSymlinksInPath` strips the `/private` prefix, and this is the same spelling
        // `AppModel.documentKey` would produce for the same file.
        #expect(entry.name == "etclink")
        #expect(entry.path == "/etc")
        // A link to a folder is a folder, even though the resource key on the link says otherwise
        // and `/etc` is itself a second symlink underneath.
        #expect(entry.isDirectory)

        do {
            _ = try fixture.lister.list(entry.path, fileExtensions: readable, limit: DirectoryLimits.pageSize)
            Issue.record("a symlink out of the workspace was followed")
        } catch {
            #expect(error.code == "grant.outsideWorkspace")
        }
    }

    /// The other half of the case above, so the symlink handling cannot be passing by denying
    /// everything: a link to a folder *inside* the grant is a folder, and descending it works.
    @Test func followsASymlinkThatStaysInsideTheWorkspace() throws {
        let fixture = try makeFixture()
        let real = try makeDirectory("q4", in: fixture.workspace)
        try write("revenue.xlsx", in: real)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("alias"),
            withDestinationURL: real
        )

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )
        let entry = try #require(listing.entries.first { $0.name == "alias" })

        #expect(entry.isDirectory)
        // The link collapses onto its destination, so `q4` and `alias` are one node rather than
        // two — which is what stops the tree above drawing the same folder twice.
        #expect(entry.path == "\(fixture.canonicalWorkspacePath)/q4")

        let descended = try fixture.lister.list(
            entry.path,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )
        #expect(descended.entries.map(\.name) == ["revenue.xlsx"])
    }

    // MARK: - What one directory looks like

    /// Directories first, then files by name; hidden files and unmatched extensions never appear,
    /// and every path handed back is canonical.
    @Test func listsDirectoriesFirstThenMatchingFilesByName() throws {
        let fixture = try makeFixture()
        try write("a.xlsx", in: fixture.workspace)
        try write("b.csv", in: fixture.workspace)
        try write("notes.md", in: fixture.workspace)
        try write(".hidden.xlsx", in: fixture.workspace)
        try makeDirectory("sub", in: fixture.workspace)

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.entries.map(\.name) == ["sub", "a.xlsx", "b.csv"])
        #expect(listing.omittedCount == 0)
        #expect(listing.isReadable)
        // The listing is keyed on the canonical path, not the spelling it was asked with, so a
        // listing that arrives late can be matched to the row that asked for it.
        #expect(listing.path == fixture.canonicalWorkspacePath)
        #expect(listing.entries[1].path == "\(fixture.canonicalWorkspacePath)/a.xlsx")
        // No trailing slash on a folder, so a directory entry's id round-trips: feeding it back
        // to `list` returns a listing whose `path` is that same string. Two spellings would be
        // two nodes in the tree above.
        #expect(listing.entries[0].path == "\(fixture.canonicalWorkspacePath)/sub")
        let descended = try fixture.lister.list(
            listing.entries[0].path,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )
        #expect(descended.path == listing.entries[0].path)

        #expect(listing.entries[0].isDirectory)
        #expect(listing.entries[0].byteCount == nil, "a folder's size is not a number we know")
        #expect(listing.entries[1].isDirectory == false)
        #expect(listing.entries[1].byteCount == 4)
        #expect(listing.entries[1].modifiedAt != nil)
    }

    /// `Q2` before `Q10`, `á` filed under `a`, `q` filed with `Q` — the order a person reading the
    /// folder would put them in, which is what `.numeric` and the two insensitive options buy.
    ///
    /// No two names here compare as equal under those options, on purpose: `Swift.sort` is not
    /// stable, so a case asserting an order between two names it considers the same would pass or
    /// fail on the whim of the introsort.
    @Test func sortsNumericallyAndInsensitively() throws {
        let fixture = try makeFixture()
        for name in ["Q10.xlsx", "q2.xlsx", "Q1.xlsx", "Zulu.csv", "ábacus.csv"] {
            try write(name, in: fixture.workspace)
        }

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.entries.map(\.name) == ["ábacus.csv", "Q1.xlsx", "q2.xlsx", "Q10.xlsx", "Zulu.csv"])
    }

    /// An `.app` is a directory the whole system draws as a document. It is never expandable, and
    /// because the extension filter then drops it, never listed at all — reached directly or
    /// through an alias, which is the route the symlink branch could otherwise have opened.
    @Test func treatsAPackageAsAFileAndSoNeverListsIt() throws {
        let fixture = try makeFixture()
        let bundle = try makeDirectory("Thing.app", in: fixture.workspace)
        try makeDirectory("Contents", in: bundle)
        try FileManager.default.createSymbolicLink(
            at: fixture.workspace.appendingPathComponent("applink"),
            withDestinationURL: bundle
        )
        try write("budget.xlsx", in: fixture.workspace)

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.entries.contains { $0.isDirectory } == false, "a package must never be a folder here")
        #expect(listing.entries.map(\.name) == ["budget.xlsx"])
    }

    // MARK: - Budgets

    /// 600 files, 500 shown, and the other 100 counted rather than swallowed. A list that
    /// silently stops is a list that lies about what is in the folder.
    @Test func capsThePageAndReportsWhatItDropped() throws {
        let fixture = try makeFixture()
        for index in 0 ..< 600 {
            try write("book-\(index).xlsx", in: fixture.workspace)
        }

        let listing = try fixture.lister.list(fixture.workspacePath, fileExtensions: readable, limit: 500)

        #expect(listing.entries.count == 500)
        #expect(listing.omittedCount == 100)
        // Sorted *before* truncation, so the page is the first 500 of the folder rather than an
        // arbitrary 500 that happen to be sorted.
        #expect(listing.entries.first?.name == "book-0.xlsx")
        #expect(listing.entries.last?.name == "book-499.xlsx")
    }

    /// A caller asking for zero rows, or for a million, gets a page. Clamping is silent because
    /// ``DirectoryListing/omittedCount`` already tells the truth about what was dropped.
    @Test func clampsTheLimitRatherThanTrapping() throws {
        let fixture = try makeFixture()
        try write("a.xlsx", in: fixture.workspace)
        try write("b.csv", in: fixture.workspace)
        try makeDirectory("sub", in: fixture.workspace)

        let floor = try fixture.lister.list(fixture.workspacePath, fileExtensions: readable, limit: 0)
        #expect(floor.entries.map(\.name) == ["sub"])
        #expect(floor.omittedCount == 2)

        let ceiling = try fixture.lister.list(fixture.workspacePath, fileExtensions: readable, limit: 99_999)
        #expect(ceiling.entries.count == 3)
        #expect(ceiling.omittedCount == 0)

        let negative = try fixture.lister.list(fixture.workspacePath, fileExtensions: readable, limit: -1)
        #expect(negative.entries.count == 1)
    }

    /// An empty extension set is a filter that matches nothing, not a filter that is off.
    /// Directories survive it, because what is inside them is not known yet.
    @Test func anEmptyExtensionSetKeepsOnlyDirectories() throws {
        let fixture = try makeFixture()
        try write("a.xlsx", in: fixture.workspace)
        try makeDirectory("sub", in: fixture.workspace)

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: [],
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.entries.map(\.name) == ["sub"])
    }

    // MARK: - Unreadable

    /// A permitted folder the OS will not open is a row to draw, not a failure to propagate.
    ///
    /// The `chmod` is reversed at the end so the scratch directory can still delete itself —
    /// otherwise every run of this suite leaves an undeletable folder in `NSTemporaryDirectory()`.
    @Test func returnsAnUnreadableListingRatherThanThrowing() throws {
        let fixture = try makeFixture()
        let closed = try makeDirectory("closed", in: fixture.workspace)
        try write("budget.xlsx", in: closed)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }

        let listing = try fixture.lister.list(
            closed.path(percentEncoded: false),
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.isReadable == false)
        #expect(listing.entries.isEmpty)
        #expect(listing.omittedCount == 0)
        // Still keyed on the canonical path, so the row that asked for it can match the answer.
        #expect(listing.path == closed.resolvingSymlinksInPath().standardized.path(percentEncoded: false))
    }

    /// ``DirectoryListing/unreadable`` is the one piece of pure logic in the contract, and the
    /// lister's only way of saying "permitted, would not open". Asserted directly so a change to
    /// it fails here rather than as a puzzling empty folder three layers up.
    @Test func theUnreadableListingIsEmptyAndSaysSo() {
        let listing = DirectoryListing.unreadable("/private/tmp/nowhere")

        #expect(listing.path == "/private/tmp/nowhere")
        #expect(listing.entries.isEmpty)
        #expect(listing.omittedCount == 0)
        #expect(listing.isReadable == false)
        // Distinct from an empty-but-readable folder, which is the distinction the whole flag
        // exists to carry.
        #expect(listing != DirectoryListing(path: "/private/tmp/nowhere", entries: []))
    }

    /// An empty granted folder is readable and empty — the other half of the distinction above.
    @Test func anEmptyDirectoryIsReadable() throws {
        let fixture = try makeFixture()

        let listing = try fixture.lister.list(
            fixture.workspacePath,
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.isReadable)
        #expect(listing.entries.isEmpty)
    }

    // MARK: - Wiring

    /// ``SheetStore`` hands out a lister over its own grants, so the app has no reason to build
    /// a second one over a second boundary.
    @Test func sheetStoreExposesAListerOverItsOwnGrants() throws {
        let scratch = TemporaryDirectory("lister-store")
        let store = try SheetStore(mode: .app, configuration: .init(applicationSupport: scratch.url))
        let workspace = scratch.directory("work")
        try write("a.xlsx", in: workspace)
        try store.grantWorkspace(UserGrantAuthorization(unchecked: workspace))

        let listing = try store.directories.list(
            workspace.path(percentEncoded: false),
            fileExtensions: readable,
            limit: DirectoryLimits.pageSize
        )

        #expect(listing.entries.map(\.name) == ["a.xlsx"])
        #expect(throws: SheetError.self) {
            try store.directories.list("/etc", fileExtensions: readable, limit: DirectoryLimits.pageSize)
        }
    }
}
