import Foundation
import SheetModel
import SheetStore
import Synchronization
import Testing

@testable import DocumentCore

/// What the workspace tree does with a granted folder: which rows exist, when it reads a
/// directory, and — mostly — when it refuses to.
///
/// # Why none of this touches a filesystem
///
/// ``DocumentCore/WorkspaceTree`` takes `any DirectoryListingSource` for exactly this reason. The
/// rules worth asserting are about *laziness*: a folder must not be listed until it is opened,
/// must not be listed twice because somebody double-clicked, and must not be listed again at all
/// once it is cached. Every one of those is a statement about how many times a call happened, and
/// a fake that counts calls proves it in microseconds where a real directory would prove it
/// slowly and only on the machine it was written on.
///
/// The budgets are the other half. `~/Documents` holds 77,024 directories on the machine this was
/// measured against; a fake that synthesises an unbounded tree exercises the depth cap and the
/// search budget honestly, which no fixture directory could.
@Suite("Workspace tree")
@MainActor
struct WorkspaceTreeTests {
    // MARK: - Roots

    @Test("A root inside another root is not a second top-level row")
    func nestedRootIsFoldedIntoItsParent() {
        // Both are granted on the developer's machine today. Two rows would mean one directory
        // with two independent expansion states.
        let tree = makeTree(FakeDirectorySource())
        tree.setRoots(["/a", "/a/b"])
        #expect(tree.nodes.map(\.id) == ["/a"])
        #expect(tree.nodes.first?.kind == .root)
        #expect(tree.nodes.first?.depth == 0)
        #expect(tree.nodes.first?.name == "a")
    }

    @Test("Containment is by component, not by string prefix")
    func siblingWithASharedPrefixSurvives() {
        // `/Users/qui` is a prefix of `/Users/quino` and a parent of nothing in it.
        let tree = makeTree(FakeDirectorySource())
        tree.setRoots(["/Users/qui", "/Users/quino"])
        #expect(tree.nodes.map(\.id) == ["/Users/qui", "/Users/quino"])
        #expect(!WorkspaceTree.isDescendant("/Users/quino", of: "/Users/qui"))
        #expect(WorkspaceTree.isDescendant("/Users/quino/Reports", of: "/Users/quino"))
        #expect(!WorkspaceTree.isDescendant("/Users/quino", of: "/Users/quino"))
    }

    @Test("The same folder spelled twice is one root")
    func duplicateRootsCollapse() {
        let tree = makeTree(FakeDirectorySource())
        tree.setRoots(["/a", "/a/", "/a/b/.."])
        #expect(tree.nodes.map(\.id) == ["/a"])
    }

    // MARK: - Expanding

    @Test("Opening a folder shows a spinner, then its children one level down")
    func expandingListsOneLevel() async {
        let source = FakeDirectorySource([
            "/a": listing("/a", [folder("/a/sub"), file("/a/one.csv"), file("/a/two.xlsx", bytes: 12)]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/a")
        #expect(tree.nodes.first?.load == .loading)
        #expect(tree.nodes.count == 1, "a folder that is still loading has no children to show yet")

        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/a", "/a/sub", "/a/one.csv", "/a/two.xlsx"])
        #expect(tree.nodes.dropFirst().allSatisfy { $0.depth == 1 })
        #expect(tree.nodes.map(\.kind) == [.root, .folder, .file, .file])
        #expect(tree.nodes.last?.byteCount == 12)
        #expect(tree.nodes.first?.load == .loaded(omitted: 0))
        #expect(source.calls(for: "/a") == 1)
        #expect(source.calls(for: "/a/sub") == 0, "a folder nobody opened is a folder nobody read")
    }

    @Test("Turning the same triangle twice reads the directory once and leaves it closed")
    func doubleToggleCoalescesIntoOneRead() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/a")
        tree.toggle("/a")
        #expect(tree.nodes.first?.isExpanded == false)

        await tree.settled()
        #expect(source.calls(for: "/a") == 1)
        #expect(tree.nodes.map(\.id) == ["/a"], "the listing landed against a row that is closed")
        #expect(tree.nodes.first?.isExpanded == false)
    }

    @Test("A folder is read once; re-opening uses the cache and refresh does not")
    func reopeningIsFreeAndRefreshIsNot() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/a")
        await tree.settled()
        #expect(source.calls(for: "/a") == 1)

        tree.toggle("/a")
        tree.toggle("/a")
        await tree.settled()
        #expect(source.calls(for: "/a") == 1, "the children were already in hand")
        #expect(tree.nodes.map(\.id) == ["/a", "/a/one.csv"])

        tree.refresh("/a")
        await tree.settled()
        #expect(source.calls(for: "/a") == 2, "exactly one more, not one per descendant")
        #expect(tree.nodes.map(\.id) == ["/a", "/a/one.csv"])
    }

    @Test("A folder the OS will not open is drawn as closed, not thrown")
    func unreadableFolderIsARowNotAnError() async {
        let source = FakeDirectorySource(["/a": DirectoryListing.unreadable("/a")])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/a")
        await tree.settled()
        #expect(tree.nodes.first?.load == .unreadable)
        #expect(tree.nodes.count == 1)
        #expect(tree.nodes.first?.isExpanded == true, "it is open; there is simply nothing behind it")
    }

    @Test("A directory the lister refused is indistinguishable from one that would not open")
    func refusedListingIsUnreadable() async {
        // The fake has no entry for `/a`, which is what a `pathOutsideWorkspace` throw looks like
        // from up here. Both mean the same thing to a row: this branch does not open.
        let tree = makeTree(FakeDirectorySource())
        tree.setRoots(["/a"])
        tree.toggle("/a")
        await tree.settled()
        #expect(tree.nodes.first?.load == .unreadable)
        #expect(tree.nodes.count == 1)
    }

    @Test("A truncated listing says how much it dropped")
    func omittedCountSurvivesIntoTheNode() async {
        let source = FakeDirectorySource([
            "/a": listing("/a", [file("/a/one.csv")], omitted: 100),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/a")
        await tree.settled()
        #expect(tree.nodes.first?.load == .loaded(omitted: 100))
    }

    @Test("The tree stops at its depth cap without reading anything")
    func expandingAtTheDepthCapReadsNothing() async {
        let source = DeepDirectorySource(subdirectories: 1, files: 0)
        let tree = makeTree(source)
        var path = "/a"
        tree.setRoots([path])

        for _ in 0 ..< DirectoryLimits.maximumDepth {
            tree.toggle(path)
            let child = path + "/d"
            await tree.settled()
            #expect(tree.nodes.contains { $0.id == child })
            path = child
        }
        #expect(tree.nodes.last?.id == path)
        #expect(tree.nodes.last?.depth == DirectoryLimits.maximumDepth)

        let before = source.callCount
        tree.toggle(path)
        await tree.settled()
        #expect(source.callCount == before, "a symlink loop that survived canonicalisation stops here")
        #expect(tree.nodes.last?.load == .unreadable)
        #expect(tree.nodes.last?.isExpanded == false)
    }

    // MARK: - Validation

    @Test("An id the tree has never heard of is ignored")
    func unknownIdsAreNoOps() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.toggle("/nowhere")
        tree.refresh("/nowhere")
        tree.removeRoot("/nowhere")
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/a"])
        #expect(source.callCount == 0)
    }

    @Test("A file has nothing to open")
    func togglingAFileDoesNothing() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])
        tree.toggle("/a")
        await tree.settled()

        tree.toggle("/a/one.csv")
        await tree.settled()
        #expect(source.calls(for: "/a/one.csv") == 0)
        #expect(tree.nodes.last?.isExpanded == false)
    }

    // MARK: - Removing a root

    @Test("Removing a root takes its subtree with it and leaves the grant alone")
    func removeRootDropsTheWholeSubtree() async {
        // Nothing in this type can reach `WorkspaceGrants` — it holds a listing source and
        // nothing else — so "does not revoke" is structural. What is worth asserting is that the
        // row and everything under it goes, and that the sibling root does not.
        let source = FakeDirectorySource([
            "/a": listing("/a", [folder("/a/sub")]),
            "/a/sub": listing("/a/sub", [file("/a/sub/deep.csv")]),
            "/z": listing("/z", [file("/z/other.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a", "/z"])

        tree.toggle("/a")
        await tree.settled()
        #expect(tree.nodes.contains { $0.id == "/a/sub" })
        tree.toggle("/a/sub")
        await tree.settled()

        tree.removeRoot("/a")
        #expect(tree.nodes.map(\.id) == ["/z"])
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/z"], "no listing lands late and puts the subtree back")
    }

    @Test("Adding a root leaves the other roots' expansion alone")
    func setRootsKeepsExpansionForSurvivors() async {
        let source = FakeDirectorySource([
            "/a": listing("/a", [file("/a/one.csv")]),
            "/z": listing("/z", [file("/z/other.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a"])
        tree.toggle("/a")
        await tree.settled()

        tree.setRoots(["/a", "/z"])
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/a", "/a/one.csv", "/z"])
        #expect(source.calls(for: "/a") == 1, "a surviving root is not re-read")
    }

    // MARK: - Granting

    @Test("A folder that is already a row opens on grant, trailing slash and all")
    func expandNewRootOpensAnExistingCollapsedRoot() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])
        #expect(tree.nodes.first?.isExpanded == false)

        // `isDirectory: true` is the shape `NSOpenPanel` hands back for a folder, and it is what
        // puts the trailing slash on `path(percentEncoded:)`. Passing that spelling to `toggle`
        // would match no node and be dropped in silence, which is the bug this method removes.
        let granted = URL(fileURLWithPath: "/a", isDirectory: true)
        #expect(granted.path(percentEncoded: false) == "/a/")
        tree.expandNewRoot(granted)

        await tree.settled()
        #expect(tree.nodes.first?.isExpanded == true)
        #expect(tree.nodes.map(\.id) == ["/a", "/a/one.csv"])
        #expect(source.calls(for: "/a") == 1)
    }

    @Test("A folder granted before its row exists still opens")
    func expandNewRootSurvivesArrivingFirst() async {
        // The ordering `AppModel` actually produces is the other one — `grantWorkspace` calls
        // `reloadGrants()` synchronously — so this is the case that must not be load-bearing.
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)

        tree.expandNewRoot(URL(fileURLWithPath: "/a", isDirectory: true))
        #expect(tree.nodes.isEmpty)
        await tree.settled()
        #expect(source.callCount == 0, "there is nothing to list until a root contains it")

        tree.setRoots(["/a"])
        await tree.settled()
        #expect(tree.nodes.first?.isExpanded == true)
        #expect(source.calls(for: "/a") == 1)
    }

    @Test("Granting the same folder twice reads it once")
    func expandNewRootIsIdempotent() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        let granted = URL(fileURLWithPath: "/a", isDirectory: true)
        tree.expandNewRoot(granted)
        tree.expandNewRoot(granted)

        await tree.settled()
        #expect(source.calls(for: "/a") == 1)
        #expect(tree.nodes.first?.isExpanded == true)
    }

    @Test("A folder granted inside an existing root opens the chain down to it")
    func expandNewRootOpensNestedAncestors() async {
        // `setRoots` drops a nested grant as a top-level row, so without the ancestor chain this
        // would be a grant that visibly did nothing — the same bug in a different costume.
        #expect(WorkspaceTree.chain(from: "/a", to: "/a/sub/deep") == ["/a", "/a/sub", "/a/sub/deep"])
        #expect(WorkspaceTree.chain(from: "/a", to: "/a") == ["/a"])

        let source = FakeDirectorySource([
            "/a": listing("/a", [folder("/a/sub")]),
            "/a/sub": listing("/a/sub", [folder("/a/sub/deep")]),
            "/a/sub/deep": listing("/a/sub/deep", [file("/a/sub/deep/leaf.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.expandNewRoot(URL(fileURLWithPath: "/a/sub/deep", isDirectory: true))
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/a", "/a/sub", "/a/sub/deep", "/a/sub/deep/leaf.csv"])
        #expect(tree.nodes.map(\.depth) == [0, 1, 2, 3])
    }

    // MARK: - Pinning

    @Test("A folder opened inside a granted one becomes the first root, and the outer one stays")
    func pinningANestedFolderPutsItFirst() async {
        // The case the nested-root rule was eating: four grants on the real machine, every one of
        // them inside `~/Documents`, every one of them folded away into nothing visible.
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/github")]),
            "/docs/github/proj": listing("/docs/github/proj", [file("/docs/github/proj/one.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        #expect(tree.pinnedRoots.isEmpty)

        tree.pin(URL(fileURLWithPath: "/docs/github/proj", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/github/proj"])
        #expect(tree.nodes.map(\.id) == ["/docs/github/proj", "/docs/github/proj/one.csv", "/docs"])
        #expect(tree.nodes.first?.kind == .root)
        #expect(tree.nodes.first?.depth == 0)
        #expect(tree.nodes.first?.name == "proj", "a root is named for its folder, not its path")
        #expect(tree.nodes.last?.id == "/docs", "the grant it lives inside is still a row of its own")
    }

    @Test("Pinning opens the folder and reads exactly one directory")
    func pinningExpandsWithASingleListing() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/one.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])

        // `isDirectory: true` is what `NSOpenPanel` hands back, trailing slash and all.
        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        #expect(tree.nodes.first?.load == .loading)

        await tree.settled()
        #expect(tree.nodes.first?.isExpanded == true)
        #expect(tree.nodes.map(\.id) == ["/docs/proj", "/docs/proj/one.csv", "/docs"])
        #expect(source.calls(for: "/docs/proj") == 1)
        #expect(source.calls(for: "/docs") == 0, "reaching the pin must not read the folder above it")
        #expect(source.callCount == 1)

        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()
        #expect(source.callCount == 1, "pinning what is already pinned reads nothing")
    }

    @Test("A folder no grant covers is not pinned and is not read")
    func pinningOutsideEveryGrantIsANoOp() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [file("/docs/one.csv")]),
            "/elsewhere/secret": listing("/elsewhere/secret", [file("/elsewhere/secret/keys.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])

        tree.pin(URL(fileURLWithPath: "/elsewhere/secret", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots.isEmpty)
        #expect(tree.nodes.map(\.id) == ["/docs"], "the tree never lists a folder no grant covers")
        #expect(source.callCount == 0)

        // The same answer before any grant has arrived — `pin` has no pending queue, unlike
        // `expandNewRoot`, so the app layer has to grant first.
        let empty = makeTree(source)
        empty.pin(URL(fileURLWithPath: "/docs", isDirectory: true))
        await empty.settled()
        #expect(empty.pinnedRoots.isEmpty)
        #expect(empty.nodes.isEmpty)
    }

    @Test("Revoking the grant the pin lived inside clears the pin")
    func revokedGrantClearsThePin() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/one.csv")]),
            "/other": listing("/other", [file("/other/two.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/proj"])

        // A grant change that keeps the covering folder keeps the pin.
        tree.setRoots(["/docs", "/other"])
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/proj"])
        #expect(tree.nodes.first?.id == "/docs/proj", "still first, after the roots were replaced")

        tree.setRoots(["/other"])
        await tree.settled()
        #expect(tree.pinnedRoots.isEmpty)
        #expect(tree.nodes.map(\.id) == ["/other"])
    }

    @Test("Opening a second folder keeps the first, in the order they were opened")
    func openingASecondFolderKeepsTheFirst() async {
        // The whole point of the change: `+ → Open Folder…` twice means two folders side by side,
        // the way a multi-root workspace works, not the second one replacing the first.
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/first"), folder("/docs/second")]),
            "/docs/first": listing("/docs/first", [file("/docs/first/one.csv")]),
            "/docs/second": listing("/docs/second", [file("/docs/second/two.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])

        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        await tree.settled()
        tree.pin(URL(fileURLWithPath: "/docs/second", isDirectory: true))
        await tree.settled()

        #expect(tree.pinnedRoots == ["/docs/first", "/docs/second"])
        // Each open folder is immediately followed by its own subtree, and the pinned block comes
        // before the granted root — the prefix the app layer scopes the tree by.
        #expect(tree.nodes.map(\.id) == [
            "/docs/first", "/docs/first/one.csv",
            "/docs/second", "/docs/second/two.csv",
            "/docs",
        ])
        #expect(tree.nodes.map(\.depth) == [0, 1, 0, 1, 0])
        #expect(tree.nodes.map(\.kind) == [.root, .file, .root, .file, .root])
        #expect(source.calls(for: "/docs") == 0, "neither folder read the grant they live in")
    }

    @Test("Opening a folder that is already open neither duplicates it nor moves it")
    func pinningTheSameFolderTwiceIsIdempotent() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/first"), folder("/docs/second")]),
            "/docs/first": listing("/docs/first", [file("/docs/first/one.csv")]),
            "/docs/second": listing("/docs/second", [file("/docs/second/two.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        tree.pin(URL(fileURLWithPath: "/docs/second", isDirectory: true))
        await tree.settled()

        // Re-opening the *first* one must not send it to the back: the row somebody is pointing at
        // would jump out from under them because a menu item was chosen twice.
        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/first", "/docs/second"])
        #expect(source.calls(for: "/docs/first") == 1, "nothing to re-read; it was already open")

        // And collapsing it makes the repeat gesture mean the one thing left for it to mean.
        tree.toggle("/docs/first")
        #expect(tree.nodes.map(\.id) == ["/docs/first", "/docs/second", "/docs/second/two.csv", "/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/first", "/docs/second"])
        #expect(tree.nodes.first?.isExpanded == true)
        #expect(source.calls(for: "/docs/first") == 1, "and the children were still in hand")
    }

    @Test("Closing one open folder leaves the others alone")
    func unpinRemovesOneAndKeepsTheRest() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/first"), folder("/docs/second")]),
            "/docs/first": listing("/docs/first", [file("/docs/first/one.csv")]),
            "/docs/second": listing("/docs/second", [file("/docs/second/two.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        tree.pin(URL(fileURLWithPath: "/docs/second", isDirectory: true))
        await tree.settled()

        tree.unpin("/docs/first")
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/second"])
        #expect(tree.nodes.map(\.id) == ["/docs/second", "/docs/second/two.csv", "/docs"])
        #expect(tree.nodes.first?.depth == 0)

        // Closing is not revoking, and it is not removing either: nothing in `grantedRoots` moved.
        tree.unpin("/docs/first")
        tree.unpin("/nowhere")
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/second"], "closing what is already closed changes nothing")
        #expect(tree.nodes.map(\.id) == ["/docs/second", "/docs/second/two.csv", "/docs"])
    }

    @Test("Closing every open folder leaves the granted roots behind")
    func unpinAllEmptiesThePinnedBlock() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/first"), folder("/docs/second")]),
            "/docs/first": listing("/docs/first", [file("/docs/first/one.csv")]),
            "/docs/second": listing("/docs/second", [file("/docs/second/two.csv")]),
            "/other": listing("/other", [file("/other/three.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs", "/other"])
        tree.pin(URL(fileURLWithPath: "/docs/first", isDirectory: true))
        tree.pin(URL(fileURLWithPath: "/docs/second", isDirectory: true))
        await tree.settled()
        #expect(tree.nodes.first?.id == "/docs/first")

        tree.unpinAll()
        await tree.settled()
        #expect(tree.pinnedRoots.isEmpty)
        #expect(tree.nodes.map(\.id) == ["/docs", "/other"], "the folders are still in there")
    }

    @Test("Two open folders where one is inside the other are both rows")
    func nestedPinsAreBothRows() async {
        // The nested-root rule would eat the inner one, and the tidier-looking answer — show only
        // the outer, since it contains the inner — would be the tree overruling somebody who
        // opened both by name.
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [folder("/docs/proj/sub")]),
            "/docs/proj/sub": listing("/docs/proj/sub", [file("/docs/proj/sub/deep.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])

        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()
        tree.pin(URL(fileURLWithPath: "/docs/proj/sub", isDirectory: true))
        await tree.settled()

        #expect(tree.pinnedRoots == ["/docs/proj", "/docs/proj/sub"])
        // The inner folder is a top-level row *and* a child of the outer one. Both are true, and
        // the outer row is not quietly edited to hide the duplicate.
        #expect(tree.nodes.map(\.id) == [
            "/docs/proj", "/docs/proj/sub", "/docs/proj/sub/deep.csv",
            "/docs/proj/sub", "/docs/proj/sub/deep.csv",
            "/docs",
        ])
        #expect(tree.nodes.map(\.depth) == [0, 1, 2, 0, 1, 0])
        #expect(source.calls(for: "/docs/proj/sub") == 1, "one directory, read once, drawn twice")
    }

    @Test("Removing an open folder's row closes it")
    func removingThePinnedRootClearsThePin() async {
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/one.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()

        tree.removeRoot("/docs/proj")
        await tree.settled()
        #expect(tree.pinnedRoots.isEmpty)
        #expect(tree.nodes.map(\.id) == ["/docs"])

        // Removing the grant the pin sits inside takes the pin with it, so a pinned path is never
        // left outside every root this tree believes in.
        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/proj"])
        tree.removeRoot("/docs")
        await tree.settled()
        #expect(tree.pinnedRoots.isEmpty)
        #expect(tree.nodes.isEmpty)
    }

    @Test("Search walks the grants, not the display list")
    func searchDoesNotWalkThePinTwice() async {
        // The pin is a second top-level row for a directory already inside a root. Queueing both
        // would spend the budget twice and return every match under it twice, with one id.
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/Budget.xlsx")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/docs"])
        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()

        tree.search = "budget"
        await tree.settled()
        #expect(tree.searchResults.map(\.id) == ["/docs/proj/Budget.xlsx"])
    }

    // MARK: - Persistence

    @Test("Last session's open folders come back")
    func expansionSurvivesANewTree() async {
        let storage = RecordingTreeStorage()
        let source = FakeDirectorySource([
            "/a": listing("/a", [folder("/a/sub")]),
            "/a/sub": listing("/a/sub", [file("/a/sub/deep.csv")]),
        ])

        let first = makeTree(source, storage: storage)
        first.setRoots(["/a"])
        first.toggle("/a")
        await first.settled()
        #expect(first.nodes.contains { $0.id == "/a/sub" })
        first.toggle("/a/sub")
        await first.settled()
        #expect(storage.expandedPaths() == ["/a", "/a/sub"])

        // Restoring is top-down and one listing at a time: `/a/sub` cannot be opened until `/a`
        // has landed and revealed it.
        let second = makeTree(source, storage: storage)
        second.setRoots(["/a"])
        await second.settled()
        #expect(second.nodes.map(\.id) == ["/a", "/a/sub", "/a/sub/deep.csv"])
        #expect(second.nodes.first { $0.id == "/a" }?.isExpanded == true)
        #expect(second.nodes.first { $0.id == "/a/sub" }?.isExpanded == true)
    }

    @Test("Expansion for a folder that is no longer granted is forgotten")
    func revokedRootsAreDroppedFromStorage() async {
        let storage = RecordingTreeStorage()
        storage.setExpandedPaths(["/a", "/a/sub", "/gone"])
        let source = FakeDirectorySource(["/a": listing("/a", [folder("/a/sub")])])

        let tree = makeTree(source, storage: storage)
        tree.setRoots(["/a"])
        await tree.settled()
        #expect(!storage.expandedPaths().contains("/gone"))
        #expect(storage.expandedPaths().contains("/a"))
    }

    @Test("The open folders come back open, first, and in the order they were opened")
    func pinSurvivesANewTree() async {
        let storage = RecordingTreeStorage()
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj"), folder("/docs/alt")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/one.csv")]),
            "/docs/alt": listing("/docs/alt", [file("/docs/alt/two.csv")]),
        ])

        let first = makeTree(source, storage: storage)
        first.setRoots(["/docs"])
        first.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        first.pin(URL(fileURLWithPath: "/docs/alt", isDirectory: true))
        await first.settled()
        // The expansion set is sorted and the pins are not: one is a set, the other is an order.
        #expect(storage.treeState() == WorkspaceTreeState(
            expanded: ["/docs/alt", "/docs/proj"],
            pinnedRoots: ["/docs/proj", "/docs/alt"]
        ))

        let second = makeTree(source, storage: storage)
        second.setRoots(["/docs"])
        await second.settled()
        #expect(second.pinnedRoots == ["/docs/proj", "/docs/alt"])
        #expect(second.nodes.map(\.id) == [
            "/docs/proj", "/docs/proj/one.csv",
            "/docs/alt", "/docs/alt/two.csv",
            "/docs",
        ])

        // And a pin whose grant went away between launches is not a row, in a tree that never
        // saw the `pin` call that made it.
        let third = makeTree(source, storage: storage)
        third.setRoots(["/elsewhere"])
        await third.settled()
        #expect(third.pinnedRoots.isEmpty)
        #expect(storage.treeState().pinnedRoots.isEmpty, "and it is forgotten, not left in the preference")
    }

    @Test("A store that predates the pin still restores the open folders")
    func storageWithoutAPinStillWorks() async {
        // The conformance `AppModel` had before ``WorkspaceTreePinStorage`` existed. The tree has
        // to degrade to remembering one of the two facts rather than refusing to remember either.
        let storage = LegacyTreeStorage(["/docs"])
        let source = FakeDirectorySource([
            "/docs": listing("/docs", [folder("/docs/proj")]),
            "/docs/proj": listing("/docs/proj", [file("/docs/proj/one.csv")]),
        ])
        let tree = makeTree(source, storage: storage)
        tree.setRoots(["/docs"])
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/docs", "/docs/proj"])

        tree.pin(URL(fileURLWithPath: "/docs/proj", isDirectory: true))
        await tree.settled()
        #expect(tree.pinnedRoots == ["/docs/proj"], "opening still works; only remembering it does not")
        #expect(storage.expandedPaths() == ["/docs", "/docs/proj"])
    }

    @Test("No storage means nothing is remembered and nothing is read")
    func nilStorageRemembersNothing() async {
        // The same shape as storage that returned nothing usable — a preference row that will
        // not decode, or one that was never written. Collapsed, no error, no listing.
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source, storage: nil)
        tree.setRoots(["/a"])
        await tree.settled()
        #expect(tree.nodes.map(\.id) == ["/a"])
        #expect(tree.nodes.first?.isExpanded == false)
        #expect(source.callCount == 0)
    }

    // MARK: - Search

    @Test("Search finds files by name and ignores case and accents")
    func searchMatchesFilesAcrossTheTree() async {
        let source = FakeDirectorySource([
            "/a": listing("/a", [folder("/a/sub"), file("/a/Budget.xlsx")]),
            "/a/sub": listing("/a/sub", [file("/a/sub/Résumé.csv"), file("/a/sub/notes.csv")]),
        ])
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.search = "  bUdGeT  "
        await tree.settled()
        #expect(!tree.isSearching)
        #expect(tree.searchResults.map(\.id) == ["/a/Budget.xlsx"])
        #expect(tree.searchNote == nil)

        tree.search = "resume"
        await tree.settled()
        #expect(tree.searchResults.map(\.id) == ["/a/sub/Résumé.csv"])
        #expect(tree.searchResults.first?.kind == .file)

        tree.search = ""
        #expect(tree.searchResults.isEmpty)
        #expect(!tree.isSearching)
        #expect(tree.searchNote == nil)
    }

    @Test("A search that runs out of budget says so instead of saying nothing")
    func searchAdmitsWhenItStoppedEarly() async {
        // Five subdirectories per directory, so the directory budget is reached long before the
        // entry budget — which is the shape `~/Documents` has, with its 77,024 directories.
        let source = DeepDirectorySource(subdirectories: 5, files: 1)
        let tree = makeTree(source)
        tree.setRoots(["/a"])

        tree.search = "nothing-matches-this"
        await tree.settled()
        #expect(!tree.isSearching)
        #expect(tree.searchNote != nil)
        #expect(tree.searchResults.isEmpty)
        #expect(source.callCount <= DirectoryLimits.searchDirectoryBudget)
    }

    @Test("Search does not read the tree, and the tree does not read search")
    func searchLeavesTheExpandedTreeAlone() async {
        let source = FakeDirectorySource(["/a": listing("/a", [file("/a/one.csv")])])
        let tree = makeTree(source)
        tree.setRoots(["/a"])
        tree.search = "one"
        await tree.settled()
        #expect(!tree.isSearching)
        #expect(tree.nodes.map(\.id) == ["/a"], "a search must not expand anything on screen")
        #expect(tree.searchResults.map(\.id) == ["/a/one.csv"])
    }

    // MARK: - Helpers

    private func makeTree(
        _ source: any DirectoryListingSource,
        storage: (any WorkspaceTreeStorage)? = nil
    ) -> WorkspaceTree {
        WorkspaceTree(source: source, fileExtensions: ["csv", "xlsx"], storage: storage)
    }

    private func listing(_ path: String, _ entries: [DirectoryEntry], omitted: Int = 0) -> DirectoryListing {
        DirectoryListing(path: path, entries: entries, omittedCount: omitted)
    }

    private func folder(_ path: String) -> DirectoryEntry {
        DirectoryEntry(path: path, name: WorkspaceTree.components(path).last ?? path, isDirectory: true)
    }

    private func file(_ path: String, bytes: Int64? = nil) -> DirectoryEntry {
        DirectoryEntry(
            path: path,
            name: WorkspaceTree.components(path).last ?? path,
            isDirectory: false,
            byteCount: bytes
        )
    }
}

// MARK: - Fakes

/// Canned listings and a call log. `Mutex` rather than plain storage because
/// ``SheetStore/DirectoryListingSource`` is `Sendable` and is read from a detached task.
private final class FakeDirectorySource: DirectoryListingSource {
    private let state: Mutex<State>

    private struct State {
        var listings: [String: DirectoryListing]
        var calls: [String] = []
    }

    init(_ listings: [String: DirectoryListing] = [:]) {
        state = Mutex(State(listings: listings))
    }

    func list(_ path: String, fileExtensions _: Set<String>, limit _: Int) throws(SheetError) -> DirectoryListing {
        // The throw is outside the lock because a typed `throws(SheetError)` will not infer
        // through `Mutex.withLock`, whose closure is generic over `any Error`.
        let listing = state.withLock { inner -> DirectoryListing? in
            inner.calls.append(path)
            return inner.listings[path]
        }
        guard let listing else { throw SheetError.pathOutsideWorkspace(path: path) }
        return listing
    }

    func calls(for path: String) -> Int { state.withLock { $0.calls.count { $0 == path } } }

    var callCount: Int { state.withLock { $0.calls.count } }
}

/// A tree with no bottom: every directory contains `subdirectories` more of them.
///
/// This is what the depth cap and the search budgets are actually for. A fixture directory deep
/// or wide enough to prove they work would be a fixture directory nobody would agree to check in.
private final class DeepDirectorySource: DirectoryListingSource {
    private let subdirectories: Int
    private let files: Int
    private let calls = Mutex(0)

    init(subdirectories: Int, files: Int) {
        self.subdirectories = subdirectories
        self.files = files
    }

    func list(_ path: String, fileExtensions _: Set<String>, limit _: Int) throws(SheetError) -> DirectoryListing {
        calls.withLock { $0 += 1 }
        var entries: [DirectoryEntry] = []
        if subdirectories == 1 {
            // Named so a test can predict the path it is about to open.
            entries.append(DirectoryEntry(path: path + "/d", name: "d", isDirectory: true))
        } else {
            for index in 0 ..< subdirectories {
                entries.append(DirectoryEntry(path: "\(path)/d\(index)", name: "d\(index)", isDirectory: true))
            }
        }
        for index in 0 ..< files {
            entries.append(DirectoryEntry(path: "\(path)/f\(index).csv", name: "f\(index).csv", isDirectory: false))
        }
        return DirectoryListing(path: path, entries: entries)
    }

    var callCount: Int { calls.withLock { $0 } }
}

/// An explorer preference that lives for the length of one test.
///
/// A `Mutex` rather than a bare `var` because ``DocumentCore/WorkspaceTreeStorage`` is `Sendable`
/// and its setter is not `mutating` — the protocol is shaped for a store that is shared, which is
/// exactly what makes it usable from a `@MainActor` tree and a background lister at once.
private final class RecordingTreeStorage: WorkspaceTreePinStorage {
    private let state = Mutex(WorkspaceTreeState())

    func expandedPaths() -> [String] { state.withLock { $0.expanded } }

    func setExpandedPaths(_ newPaths: [String]) { state.withLock { $0.expanded = newPaths } }

    func treeState() -> WorkspaceTreeState { state.withLock { $0 } }

    func setTreeState(_ newState: WorkspaceTreeState) { state.withLock { $0 = newState } }
}

/// A store from before the pin existed: the base protocol, and nowhere to put a pinned root.
///
/// Kept as its own double rather than a flag on ``RecordingTreeStorage`` because the thing under
/// test is the conditional cast in ``DocumentCore/WorkspaceTree``, and a cast can only be proved
/// by a type that genuinely fails it.
private final class LegacyTreeStorage: WorkspaceTreeStorage {
    private let paths: Mutex<[String]>

    init(_ initial: [String] = []) {
        paths = Mutex(initial)
    }

    func expandedPaths() -> [String] { paths.withLock { $0 } }

    func setExpandedPaths(_ newPaths: [String]) { paths.withLock { $0 = newPaths } }
}

/// The half of persistence that owns a `preference` row.
///
/// Serialized and on the filesystem because the point of this adapter is the round trip through
/// SQLite; a fake in front of it would test the fake. Everything else about the tree is proved
/// against ``RecordingTreeStorage`` instead, which is why this suite is three cases long.
@Suite("Workspace tree storage", .serialized)
struct DatabaseWorkspaceTreeStorageTests {
    @Test("Expanded paths round-trip through the preference table")
    func pathsRoundTrip() throws {
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        let storage = DatabaseWorkspaceTreeStorage(database: scratch.database)

        #expect(storage.expandedPaths().isEmpty, "an unwritten preference is not an error")
        storage.setExpandedPaths(["/Users/x/Reports", "/Users/x"])
        #expect(storage.expandedPaths() == ["/Users/x/Reports", "/Users/x"])
        storage.setExpandedPaths([])
        #expect(storage.expandedPaths().isEmpty)
    }

    @Test("The open folders round-trip beside the expanded paths")
    func pinRoundTrips() throws {
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        let storage = DatabaseWorkspaceTreeStorage(database: scratch.database)
        let open = WorkspaceTreeState(expanded: ["/Users/x"], pinnedRoots: ["/Users/x/Reports", "/Users/x"])

        #expect(storage.treeState() == WorkspaceTreeState(), "an unwritten preference is not an error")
        storage.setTreeState(open)
        #expect(storage.treeState() == open, "and the order they were opened in comes back with them")
        #expect(storage.expandedPaths() == ["/Users/x"])

        // One row holds both, so a caller that only knows the older protocol must not erase the
        // half it cannot see.
        storage.setExpandedPaths(["/Users/x", "/Users/x/Reports"])
        #expect(storage.treeState().pinnedRoots == ["/Users/x/Reports", "/Users/x"])

        storage.setTreeState(WorkspaceTreeState(expanded: ["/Users/x"]))
        #expect(storage.treeState().pinnedRoots.isEmpty)
    }

    @Test("A value written before the pin existed still reads as an expansion set")
    func legacyBareArrayStillDecodes() throws {
        // There are databases holding exactly this today. Reading it as "nothing expanded" would
        // discard a preference on the one launch where nobody would connect the two.
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        try scratch.database.setPreference(DatabaseWorkspaceTreeStorage.preferenceKey, to: #"["/tmp/x"]"#)
        let storage = DatabaseWorkspaceTreeStorage(database: scratch.database)
        #expect(storage.expandedPaths() == ["/tmp/x"])
        #expect(storage.treeState() == WorkspaceTreeState(expanded: ["/tmp/x"], pinnedRoots: []))

        // And the upgrade is one-way: what goes back is the object form.
        storage.setExpandedPaths(["/tmp/x"])
        let raw = try scratch.database.preference(DatabaseWorkspaceTreeStorage.preferenceKey)
        #expect(raw == #"{"expanded":["/tmp/x"]}"#)
    }

    @Test("A single pinned root written by the last release becomes one open folder")
    func legacySinglePinBecomesAList() throws {
        // The shape shipped between the bare array and this one. A session that had one folder
        // open should find that folder open again, not find the explorer reset.
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        try scratch.database.setPreference(
            DatabaseWorkspaceTreeStorage.preferenceKey,
            to: #"{"expanded":["/x"],"pinnedRoot":"/x"}"#
        )
        let storage = DatabaseWorkspaceTreeStorage(database: scratch.database)
        #expect(storage.treeState() == WorkspaceTreeState(expanded: ["/x"], pinnedRoots: ["/x"]))

        // And the next write is the new shape, so the old key is read once and never again.
        storage.setTreeState(storage.treeState())
        let raw = try scratch.database.preference(DatabaseWorkspaceTreeStorage.preferenceKey)
        #expect(raw == #"{"expanded":["/x"],"pinnedRoots":["/x"]}"#)
    }

    @Test("It writes where the rollback instructions say it does")
    func itUsesTheDocumentedKey() throws {
        // `sqlite3 … "DELETE FROM preference WHERE key='workspace.explorer';"` is the documented
        // way to reset the explorer, so the key is part of the contract rather than a detail.
        #expect(DatabaseWorkspaceTreeStorage.preferenceKey == "workspace.explorer")
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        DatabaseWorkspaceTreeStorage(database: scratch.database)
            .setTreeState(WorkspaceTreeState(expanded: ["/Users/x"], pinnedRoots: ["/Users/x"]))
        let raw = try scratch.database.preference(DatabaseWorkspaceTreeStorage.preferenceKey)
        // Slashes unescaped and keys sorted, because somebody reads this row in `sqlite3`.
        #expect(raw == #"{"expanded":["/Users/x"],"pinnedRoots":["/Users/x"]}"#)
    }

    @Test("A value that is not a list of paths reads as nothing expanded")
    func garbageDegradesToEmpty() throws {
        let scratch = try TemporaryDatabase()
        defer { scratch.remove() }
        try scratch.database.setPreference(DatabaseWorkspaceTreeStorage.preferenceKey, to: "{ not json")
        #expect(DatabaseWorkspaceTreeStorage(database: scratch.database).expandedPaths().isEmpty)

        try scratch.database.setPreference(DatabaseWorkspaceTreeStorage.preferenceKey, to: "{\"a\":1}")
        #expect(DatabaseWorkspaceTreeStorage(database: scratch.database).expandedPaths().isEmpty)
    }

    private struct TemporaryDatabase {
        let directory: URL
        let database: Database

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensheets-explorer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            database = try Database(url: directory.appendingPathComponent("OpenSheets.sqlite"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
