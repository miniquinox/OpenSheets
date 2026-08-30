import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// **The recursive walk, tested as a thing that has to stop.**
///
/// ``DirectoryListerTests`` proves one directory is enumerated safely. Recursion adds exactly two
/// new ways to be wrong, and both of them are failures a unit test on strings would never see: a
/// walk that never terminates, and a walk that names a place the deny-list exists to hide. So every
/// case here builds a real tree — real symlinks, a real loop, a real folder whose name matches a
/// deny rule — and asserts on the counts the walk reports rather than merely on the fact that it
/// returned.
///
/// `.serialized` for the reason the lister suite is: these are filesystem layouts, not fixtures in
/// memory.
@Suite("Directory walk — budgets, loops and the boundary", .serialized)
struct DirectoryWalkerTests {
    /// The panel's set, narrowed to the spellings these layouts use. Deliberately not
    /// ``SpreadsheetFileTypes/listable`` in most cases, so a case asserting "only matching files
    /// appear" is asserting about the filter and not about the constant.
    private let readable: Set<String> = ["xlsx", "csv"]

    private struct Fixture {
        var walker: DirectoryWalker
        var grants: WorkspaceGrants
        var scratch: TemporaryDirectory
        var workspace: URL

        var workspacePath: String { workspace.path(percentEncoded: false) }
    }

    /// A walker over one granted temp folder with the **real** deny-list — the same construction
    /// ``DirectoryListerTests`` uses, for the same reason: a permissive deny-list would make the
    /// skip cases pass by never firing.
    private func makeFixture() throws -> Fixture {
        let scratch = TemporaryDirectory("walker")
        let workspace = scratch.directory("work")
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .standard)
        try grants.grant(UserGrantAuthorization(unchecked: workspace))
        return Fixture(
            walker: DirectoryWalker(lister: DirectoryLister(grants: grants), grants: grants),
            grants: grants,
            scratch: scratch,
            workspace: workspace
        )
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

    private func link(_ name: String, in directory: URL, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(name),
            withDestinationURL: destination
        )
    }

    // MARK: - What a whole tree looks like

    /// Breadth-first, every level filtered exactly as the lister filters one, and each entry
    /// carrying the path a person would type rather than the canonical one.
    @Test func returnsTheWholeTreeBreadthFirstWithRelativePaths() throws {
        let fixture = try makeFixture()
        try write("budget.xlsx", in: fixture.workspace)
        try write("notes.md", in: fixture.workspace)
        let quarter = try makeDirectory("q4", in: fixture.workspace)
        try write("revenue.xlsx", in: quarter)
        let deep = try makeDirectory("deep", in: quarter)
        try write("plan.csv", in: deep)

        let result = try fixture.walker.walk(root: fixture.workspacePath, fileExtensions: readable)

        // Directories before files within a level, and every level before the next one.
        #expect(result.entries.map(\.relativePath) == [
            "q4", "budget.xlsx",
            "q4/deep", "q4/revenue.xlsx",
            "q4/deep/plan.csv",
        ])
        #expect(result.entries.map(\.depth) == [1, 1, 2, 2, 3])
        #expect(result.truncated == false)
        #expect(result.stoppedBy == nil)
        #expect(result.skippedProtectedCount == 0)
        #expect(result.unreadableCount == 0)
        #expect(result.omittedCount == 0)
        // The canonical path is still what the entry carries, so what is printed and what is
        // opened cannot disagree.
        let plan = try #require(result.entries.last)
        #expect(plan.entry.path.hasSuffix("/q4/deep/plan.csv"))
        #expect(result.root == fixture.workspace.resolvingSymlinksInPath().standardized.path(percentEncoded: false))
    }

    /// The extension filter is the panel's, and it applies at every depth — not just at the top,
    /// which is the level a walk written as "list, then recurse the directories" would get right by
    /// accident.
    @Test func onlyFilesMatchingTheExtensionSetAppearAtAnyDepth() throws {
        let fixture = try makeFixture()
        let nested = try makeDirectory("nested", in: fixture.workspace)
        for name in ["a.xlsx", "b.xlsm", "c.xltx", "d.xltm", "e.csv", "f.tsv", "g.txt", "h.tab", "i.md", "j.pdf"] {
            try write(name, in: nested)
        }

        let result = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: SpreadsheetFileTypes.listable
        )

        let files = result.entries.filter { !$0.entry.isDirectory }.map(\.entry.name).sorted()
        #expect(files == ["a.xlsx", "b.xlsm", "c.xltx", "d.xltm", "e.csv", "f.tsv", "g.txt", "h.tab"])
    }

    // MARK: - The boundary, at every level

    /// A folder whose name matches a deny rule is skipped, not descended, and **not named**.
    ///
    /// The name took three attempts to pick, and the rejects are worth writing down because they
    /// are the reason this case is not spelled the obvious way. Measured on macOS 26:
    ///
    /// - `.env`, the rule's headline example, never reaches the deny check at all —
    ///   `contentsOfDirectory` is asked to skip hidden files, so a dot-name is gone a layer earlier.
    /// - A directory named `vault.key`, `vault.pem`, `vault.p12` or `vault.pfx` reports
    ///   `isPackage == true`, and ``DirectoryLister`` refuses to call any package a folder. Four of
    ///   the six filename rules are therefore unreachable through a directory.
    ///
    /// `.keychain` is the one that is neither hidden nor a package, so it is the spelling that
    /// actually exercises the boundary. Counted rather than listed on purpose: naming the folder
    /// that was skipped would tell an agent it is there, which is the fact the deny-list exists to
    /// withhold.
    @Test func aDenyListedFolderIsSkippedCountedAndNeverNamed() throws {
        let fixture = try makeFixture()
        let vault = try makeDirectory("vault.keychain", in: fixture.workspace)
        try write("secret.xlsx", in: vault)
        try write("budget.xlsx", in: fixture.workspace)

        let result = try fixture.walker.walk(root: fixture.workspacePath, fileExtensions: readable)

        #expect(result.entries.map(\.relativePath) == ["budget.xlsx"])
        #expect(result.skippedProtectedCount == 1)
        #expect(result.entries.contains { $0.relativePath.contains("vault") } == false)
    }

    /// A symlink whose destination is outside every grant is skipped the same way — the case that
    /// makes "check every entry" rather than "check the root" the rule.
    ///
    /// Both halves matter: the folder link, which the walk would otherwise descend, and the *file*
    /// link, which the lister filters by the extension of the link rather than of its destination
    /// and so hands back with a path outside the workspace.
    @Test func aSymlinkLeavingTheWorkspaceIsSkippedWhetherItIsAFolderOrAFile() throws {
        let fixture = try makeFixture()
        let outside = fixture.scratch.directory("outside")
        try write("stolen.xlsx", in: outside)
        try link("elsewhere", in: fixture.workspace, to: outside)
        try link("report.xlsx", in: fixture.workspace, to: outside.appendingPathComponent("stolen.xlsx"))
        try write("budget.xlsx", in: fixture.workspace)

        let result = try fixture.walker.walk(root: fixture.workspacePath, fileExtensions: readable)

        #expect(result.entries.map(\.relativePath) == ["budget.xlsx"])
        #expect(result.skippedProtectedCount == 2, "one folder link and one file link, both refused")
        #expect(result.entries.contains { $0.entry.path.contains("outside") } == false)
    }

    /// Walking a folder no grant covers is a refusal, not an empty tree with a skip count. Those
    /// are different answers and only one of them tells the user to grant the folder.
    @Test func aRootOutsideEveryGrantIsRefusedRatherThanWalked() throws {
        let fixture = try makeFixture()

        do {
            _ = try fixture.walker.walk(root: "/etc", fileExtensions: readable)
            Issue.record("an ungranted root was walked")
        } catch {
            #expect(error.code == "grant.outsideWorkspace")
            #expect(error.category == .security)
        }

        let denied = try makeDirectory("keys.pem", in: fixture.workspace)
        do {
            _ = try fixture.walker.walk(root: denied.path(percentEncoded: false), fileExtensions: readable)
            Issue.record("a deny-listed root was walked")
        } catch {
            #expect(error.code == "grant.denyListed")
        }
    }

    // MARK: - Loops

    /// A symlink pointing back at a folder already walked is a row, not a second traversal — so a
    /// loop terminates instead of running to the depth cap.
    ///
    /// The test would hang, or blow the depth budget, if descent were keyed on anything but the
    /// canonical path.
    @Test func aSymlinkLoopTerminatesInsteadOfDescendingForever() throws {
        let fixture = try makeFixture()
        let first = try makeDirectory("a", in: fixture.workspace)
        let second = try makeDirectory("b", in: fixture.workspace)
        try write("budget.xlsx", in: first)
        try link("toB", in: first, to: second)
        try link("toA", in: second, to: first)
        try link("toRoot", in: second, to: fixture.workspace)

        let result = try fixture.walker.walk(root: fixture.workspacePath, fileExtensions: readable)

        #expect(result.entries.map(\.relativePath).sorted() == [
            "a", "a/budget.xlsx", "a/toB", "b", "b/toA", "b/toRoot",
        ])
        // Every alias is drawn, because the user can see it in the Finder — but each real folder
        // was opened exactly once, which is what makes the walk finite.
        #expect(result.truncated == false)
        #expect(result.stoppedBy == nil)
    }

    // MARK: - Budgets

    /// The entry budget stops the walk and says which one did it. A list that silently stops is a
    /// list that lies about what is in the folder.
    @Test func theEntryBudgetTruncatesAndNamesItself() throws {
        let fixture = try makeFixture()
        let nested = try makeDirectory("nested", in: fixture.workspace)
        for index in 0 ..< 20 {
            try write("book-\(index).xlsx", in: nested)
        }

        let result = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: readable,
            entryBudget: 5
        )

        #expect(result.entries.count == 5)
        #expect(result.truncated)
        #expect(result.stoppedBy == .entries)
    }

    /// The depth cap prunes rather than aborting: siblings above it are still visited, and the
    /// result says the tree goes deeper than what came back.
    @Test func theDepthCapPrunesAndSaysSo() throws {
        let fixture = try makeFixture()
        var directory = fixture.workspace
        for level in 0 ..< 4 {
            directory = try makeDirectory("level-\(level)", in: directory)
            try write("book-\(level).xlsx", in: directory)
        }

        let result = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: readable,
            maxDepth: 2
        )

        #expect(result.entries.map(\.depth).max() == 2)
        #expect(result.entries.map(\.relativePath) == ["level-0", "level-0/level-1", "level-0/book-0.xlsx"])
        #expect(result.truncated)
        #expect(result.stoppedBy == .depth)
    }

    /// The directory budget counts folders opened, not entries seen, and ends the walk when it runs
    /// out — the ceiling that keeps a granted home directory from becoming a hang.
    @Test func theDirectoryBudgetEndsTheWalk() throws {
        let fixture = try makeFixture()
        for index in 0 ..< 4 {
            let child = try makeDirectory("folder-\(index)", in: fixture.workspace)
            try write("book.xlsx", in: child)
        }

        let result = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: readable,
            directoryBudget: 2
        )

        // The root plus one child: four folder rows, and the files of exactly one of them.
        #expect(result.entries.filter { !$0.entry.isDirectory }.count == 1)
        #expect(result.truncated)
        #expect(result.stoppedBy == .directories)
    }

    /// A caller cannot raise a budget above the house ceiling, and cannot lower one to zero and get
    /// a trap. Clamping is silent because ``WalkResult/truncated`` already tells the truth.
    @Test func budgetsAreClampedRatherThanTrusted() throws {
        let fixture = try makeFixture()
        try write("budget.xlsx", in: fixture.workspace)

        let greedy = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: readable,
            entryBudget: .max,
            directoryBudget: .max,
            maxDepth: .max
        )
        #expect(greedy.entries.map(\.relativePath) == ["budget.xlsx"])

        let starved = try fixture.walker.walk(
            root: fixture.workspacePath,
            fileExtensions: readable,
            entryBudget: 0,
            directoryBudget: 0,
            maxDepth: 0
        )
        #expect(starved.entries.count == 1, "a caller asking for nothing gets a page, not a crash")
    }

    // MARK: - Unreadable

    /// A permitted folder the OS will not open is counted, not thrown — and counted separately from
    /// a protected one, because only one of those two is a security answer.
    ///
    /// The `chmod` is reversed at the end so the scratch directory can still delete itself.
    @Test func anUnreadableFolderIsCountedSeparatelyFromAProtectedOne() throws {
        let fixture = try makeFixture()
        let closed = try makeDirectory("closed", in: fixture.workspace)
        try write("budget.xlsx", in: closed)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: closed.path) }

        let result = try fixture.walker.walk(root: fixture.workspacePath, fileExtensions: readable)

        #expect(result.entries.map(\.relativePath) == ["closed"], "the folder is a row; its contents are not")
        #expect(result.unreadableCount == 1)
        #expect(result.skippedProtectedCount == 0)
    }

    // MARK: - Wiring

    /// The walker composes out of a store's own lister and grants, so nothing has to build a second
    /// boundary to get a recursive listing.
    @Test func aStoreSuppliesBothHalvesOfAWalk() throws {
        let scratch = TemporaryDirectory("walker-store")
        let store = try SheetStore(mode: .app, configuration: .init(applicationSupport: scratch.url))
        let workspace = scratch.directory("work")
        let nested = try makeDirectory("q4", in: workspace)
        try write("revenue.xlsx", in: nested)
        try store.grantWorkspace(UserGrantAuthorization(unchecked: workspace))

        let walker = DirectoryWalker(lister: store.directories, grants: store.grants)
        let result = try walker.walk(
            root: workspace.path(percentEncoded: false),
            fileExtensions: SpreadsheetFileTypes.listable
        )

        #expect(result.entries.map(\.relativePath) == ["q4", "q4/revenue.xlsx"])
    }
}
