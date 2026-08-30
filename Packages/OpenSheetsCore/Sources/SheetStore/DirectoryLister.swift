import Foundation
import SheetModel

/// The only thing in this app that enumerates a folder on the user's behalf (PLAN.md §7.2).
///
/// The first statement of ``list(_:fileExtensions:limit:)`` is `grants.check(path)`, and that is
/// the entire security design. That one call canonicalises, applies the deny-list and compares by
/// path *components* — see `WorkspaceGrants.check(_:)` — so an escape has to get past code that
/// already carries a forty-three case suite, rather than past something re-derived here.
///
/// Two consequences, both load-bearing:
///
/// - **Nothing in this file decides whether a path may be read.** No second containment test, no
///   `hasPrefix`. PLAN.md §7.2 forbids the prefix form by name, because `/Users/q/work-secret`
///   starts with `/Users/q/work` and is not inside it. A duplicate check would also be the thing
///   that drifts: two boundaries can disagree, and the loose one wins.
/// - **Only the grant check throws.** A permitted folder that will not open is data, not an
///   error — it comes back as ``DirectoryListing/isReadable`` `false`. A granted home directory
///   routinely holds one of those (a `.Trash`, a sandbox container, an unmounted network share),
///   and a tree that aborted on the first would be a tree that stops working on a real machine.
///
/// **Three things this deliberately does not do.** Each is somebody else's job, and saying so
/// here is what stops the next person adding it in the wrong place:
///
/// - **No recursion.** A caller wanting a tree asks for one directory at a time and keeps its own
///   shape. That is what makes ``DirectoryLimits`` enforceable rather than advisory: a recursive
///   lister has one budget for a walk of unknown size, a caller-driven one has a budget per
///   screenful, and only the second can be answered honestly with an `omittedCount`.
/// - **No watching.** Listings are a snapshot of the instant they were taken. ``FileWatcher``
///   watches *one* file with two descriptors, and pointing that at the tens of thousands of
///   directories under a real home folder is not viable. The layer above refreshes on an explicit
///   action and when its window becomes key; a file created behind its back stays invisible until
///   then. A stated limit, not an oversight.
/// - **No caching.** Every call stats the directory again. A cache here would be a cache of
///   *permission-checked* results, which is the kind that survives a revoked grant, and the
///   listing is cheap next to the disclosure it would risk. Whoever wants one keeps it above the
///   boundary, where it can be dropped when the grant list changes.
public struct DirectoryLister: DirectoryListingSource {
    /// The security boundary. The only reason this type has a stored property at all.
    private let grants: WorkspaceGrants

    /// Everything the enumeration needs to know about a child, prefetched in one pass.
    ///
    /// Requested up front through `includingPropertiesForKeys:` so each child is one cached
    /// lookup rather than four `stat` calls; a 3,000-entry folder is where that difference is
    /// visible.
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isPackageKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    public init(grants: WorkspaceGrants) {
        self.grants = grants
    }

    /// One directory, one level deep, sorted and capped.
    ///
    /// Synchronous and `nonisolated` on purpose: the caller hops off the main actor itself, which
    /// is the house idiom (`DocumentCore/DocumentModel.swift:1451-1461`). An `async` signature
    /// here would put a suspension point in front of the grant check and buy nothing — the work
    /// is a blocking `readdir` either way, and hiding that behind `await` only makes it harder to
    /// see which actor is paying for it.
    ///
    /// - Parameters:
    ///   - path: any spelling of an absolute path inside an active grant. Canonicalised as part
    ///     of the check; the listing comes back keyed on the canonical form.
    ///   - fileExtensions: lowercase, without the dot. Files that do not match are dropped;
    ///     directories are always kept, because a folder's contents are not known yet.
    ///   - limit: clamped into `1 ... DirectoryLimits.maximumPageSize`. Clamping is silent —
    ///     a caller asking for zero rows wants a page, not a trap, and the truth about what was
    ///     dropped is in ``DirectoryListing/omittedCount`` either way.
    /// - Throws: `SheetError.pathOutsideWorkspace` or `SheetError.pathDenyListed` from the grant
    ///   check. Nothing else in this method throws.
    public nonisolated func list(
        _ path: String,
        fileExtensions: Set<String>,
        limit: Int
    ) throws(SheetError) -> DirectoryListing {
        try grants.check(path)

        let directory = URL(fileURLWithPath: path)
        let canonical = DirectoryLister.canonicalPath(directory)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(DirectoryLister.resourceKeys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            // Permitted but unopenable. See the type's doc comment: this is a row to draw, not a
            // failure to propagate.
            return DirectoryListing.unreadable(canonical)
        }

        var entries = children.compactMap { entry(for: $0, fileExtensions: fileExtensions) }
        entries.sort(by: DirectoryLister.precedes)

        let clamped = min(max(limit, 1), DirectoryLimits.maximumPageSize)
        let omitted = max(0, entries.count - clamped)
        return DirectoryListing(
            path: canonical,
            entries: omitted > 0 ? Array(entries.prefix(clamped)) : entries,
            omittedCount: omitted,
            isReadable: true
        )
    }

    /// One child, or `nil` when the extension filter drops it.
    private func entry(for child: URL, fileExtensions: Set<String>) -> DirectoryEntry? {
        let canonical = DirectoryLister.canonicalPath(child)
        var values = try? child.resourceValues(forKeys: DirectoryLister.resourceKeys)
        var resolvedIsDirectory: Bool?
        if values?.isSymbolicLink == true {
            // Every question gets asked again at the destination, because `resourceValues`
            // answers about the *link*: a symlink to a folder reports `isDirectory == false`, and
            // would fall out of the extension filter unseen. An alias to a folder is a folder to
            // the person looking at it. Asking at the resolved path also means the answer is
            // about the same place the next grant check will run against, so what is drawn and
            // what is enforced cannot disagree.
            //
            // Directoryness specifically comes from `stat` rather than from the resource key,
            // because the resolved path can *still* be a symlink: `resolvingSymlinksInPath`
            // deliberately spells `/private/etc` as `/etc`, which is itself a link, and the
            // resource key would then report a link a second time and call `/etc` a file.
            // `stat` follows the whole chain. It also answers false for a dangling link and for
            // a loop, which is exactly what those should be — unknown, and dropped.
            var isDirectoryFlag: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectoryFlag)
            resolvedIsDirectory = exists && isDirectoryFlag.boolValue
            values = try? URL(fileURLWithPath: canonical)
                .resourceValues(forKeys: DirectoryLister.resourceKeys)
        }

        // `.app`, `.rtfd` and `.bundle` are directories that every other part of the system draws
        // as documents. Treating one as a folder would turn a spreadsheet browser into a way to
        // walk an application's insides; calling it a file hands it to the extension filter
        // below, which drops it. So a package is never expandable and never listed.
        let isPackage = values?.isPackage ?? false
        let isDirectory = (resolvedIsDirectory ?? values?.isDirectory ?? false) && !isPackage
        guard isDirectory || fileExtensions.contains(child.pathExtension.lowercased()) else { return nil }

        return DirectoryEntry(
            // The canonical path — so a symlink is listed under the name the user sees but
            // identified by where it actually points, which is what makes the next `list` of it
            // get checked against the place it leads rather than the place it sits.
            path: canonical,
            // The name *in this folder*, not the last component of the resolved path. An alias
            // called `Reports` pointing at `q4-final` is `Reports` here, because that is what
            // the user is looking at in the Finder.
            name: child.lastPathComponent,
            isDirectory: isDirectory,
            // A folder's size has several defensible answers and no cheap one, and a stat that
            // failed is not a zero-byte file. Both stay unknown rather than becoming a number
            // drawn next to a file name, where it would read as fact.
            byteCount: isDirectory ? nil : values?.fileSize.map { Int64($0) },
            // Directories keep theirs: unlike size, a folder's modification time is one cheap,
            // unambiguous fact.
            modifiedAt: values?.contentModificationDate
        )
    }

    /// Directories first, then by name, case- and diacritic-insensitively and with runs of digits
    /// compared as numbers — so `Q9` sorts before `Q10` the way a person reading the folder
    /// would put them.
    ///
    /// Here rather than in a view: the order is part of the answer, every consumer wants the same
    /// one, and a comparator living inside a `ForEach` is a comparator no test can reach.
    private static func precedes(_ lhs: DirectoryEntry, _ rhs: DirectoryEntry) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.compare(
            rhs.name,
            options: [.caseInsensitive, .diacriticInsensitive, .numeric]
        ) == .orderedAscending
    }

    /// The identity everything above keys on, spelled the one way this app spells a path.
    ///
    /// The same expression as `AppModel.documentKey(for:)` (`DocumentCore/AppModel.swift:356-358`),
    /// copied rather than imported because `SheetStore` sits *below* `DocumentCore` and a
    /// dependency the other way would invert the layering. Two spellings of one path are two
    /// documents, so a tree that minted its own would open tabs the tab strip does not recognise.
    private static func canonicalPath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        // `URL(fileURLWithPath:)` stats what it is given, and a URL it has decided is a directory
        // spells itself with a trailing slash. `AppModel.documentKey` never meets that, because it
        // is only ever handed files. Here half the entries are folders, and `/x/sub/` next to
        // `/x/sub` would be two ids for one node — the exact thing keying on a canonical path is
        // meant to prevent. `WorkspaceGrant.path` carries no trailing slash either, so a granted
        // root would stop matching its own listing.
        //
        // A suffix test on one string, not a containment test between two: PLAN.md §7.2's ban on
        // `hasPrefix` is about deciding whether one path is inside another, which nothing here does.
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
