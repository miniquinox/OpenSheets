import Foundation
import SheetModel

/// One entry a walk found, and where it found it.
public struct WalkEntry: Sendable, Hashable {
    /// The entry exactly as ``DirectoryLister`` produced it — canonical path, name as spelled in
    /// its own folder, size and modification date.
    public var entry: DirectoryEntry

    /// `1` for a child of the root. The root itself is never an entry: a caller asked for its
    /// contents, and a listing that includes the folder you asked about is a listing that has to
    /// be filtered by everybody who draws it.
    public var depth: Int

    /// Slash-joined names from the root — `q4/revenue.xlsx`.
    ///
    /// Built from the *names* in each listing rather than from canonical paths, because a
    /// symlinked folder's canonical path is somewhere else entirely and this is what the caller
    /// prints. ``entry``'s `path` is still the canonical one, so what is printed and what is
    /// opened cannot disagree.
    public var relativePath: String

    public init(entry: DirectoryEntry, depth: Int, relativePath: String) {
        self.entry = entry
        self.depth = depth
        self.relativePath = relativePath
    }
}

/// Which ceiling ended a walk. See ``WalkResult/stoppedBy``.
public enum WalkLimit: Sendable, Hashable {
    /// The caller's entry budget, or ``DirectoryLimits/searchEntryBudget``.
    case entries
    /// ``DirectoryLimits/searchDirectoryBudget`` — folders opened, not entries seen.
    case directories
    /// ``DirectoryLimits/maximumDepth``. Unlike the other two this does not end the walk, it
    /// prunes it: siblings shallower than the cap are still visited.
    case depth
}

/// What a recursive walk found, and every way it is incomplete.
///
/// Every form of incompleteness is a field rather than an error, for the reason
/// ``DirectoryListing`` gives: on a real machine a granted folder routinely contains something
/// unreadable, something deny-listed and more files than any budget allows, and a walk that threw
/// on the first would be a walk that never finishes on the folder people actually granted.
public struct WalkResult: Sendable, Hashable {
    /// The canonical path that was walked, as ``DirectoryLister`` spells it.
    public var root: String

    /// Breadth-first: every child of the root, then every grandchild. Within one folder the
    /// lister's order holds — directories first, then files, numerically and insensitively by
    /// name.
    public var entries: [WalkEntry]

    /// How many entries the grant boundary refused: deny-listed names, and symlinks whose
    /// destination is outside every grant.
    ///
    /// A count and not a list, on purpose. Naming the folder that was skipped would tell an agent
    /// that `~/.ssh` is there, which is precisely the fact the deny-list exists to withhold. "3
    /// protected locations were skipped" is the honest answer that leaks nothing.
    public var skippedProtectedCount: Int

    /// How many permitted folders would not open — a `.Trash`, a sandbox container, an unmounted
    /// share. Distinct from ``skippedProtectedCount`` because the causes are different and only
    /// one of them is a security answer.
    public var unreadableCount: Int

    /// Entries dropped by ``DirectoryLimits/maximumPageSize`` inside individual folders, summed.
    /// Separate from the walk-wide budgets: this one says "that folder is bigger than a page",
    /// they say "the walk stopped".
    public var omittedCount: Int

    /// Whether anything at all was left out — any of the three limits, or a per-folder page cap.
    /// The one flag a caller must not forget to print.
    public var truncated: Bool

    /// The limit that ended the walk, or `nil` when it ran to completion. When several applied,
    /// this is the one that stopped it: ``WalkLimit/depth`` only survives here if neither budget
    /// was reached, because a pruned branch is a smaller admission than an aborted walk.
    public var stoppedBy: WalkLimit?

    public init(
        root: String,
        entries: [WalkEntry] = [],
        skippedProtectedCount: Int = 0,
        unreadableCount: Int = 0,
        omittedCount: Int = 0,
        truncated: Bool = false,
        stoppedBy: WalkLimit? = nil
    ) {
        self.root = root
        self.entries = entries
        self.skippedProtectedCount = skippedProtectedCount
        self.unreadableCount = unreadableCount
        self.omittedCount = omittedCount
        self.truncated = truncated
        self.stoppedBy = stoppedBy
    }
}

/// Breadth-first recursion over a granted folder, one ``DirectoryLister`` call per directory.
///
/// # Why this is a separate type rather than a flag on the lister
///
/// ``DirectoryLister``'s doc comment says it deliberately does not recurse, and the reason is
/// budgets: a recursive lister has one budget for a walk of unknown size, a caller-driven one has
/// a budget per screenful, and only the second can be answered honestly with an `omittedCount`.
/// That argument is still right for the Files panel, which lists a folder when a triangle is
/// turned and never before.
///
/// It is not right for an agent, which cannot turn triangles. `list_files --recursive` has to walk
/// the tree in one call, so the budgets move here — where all three of them
/// (``DirectoryLimits/searchEntryBudget``, ``DirectoryLimits/searchDirectoryBudget``,
/// ``DirectoryLimits/maximumDepth``) are enforced together and every one of them is reported.
/// The panel keeps its lazy tree; the walk gets a bounded answer; neither re-implements the other's
/// filtering, sorting or grant check, because each level here *is* a `DirectoryLister.list` call.
///
/// # The two rules that make it safe
///
/// - **Every entry re-passes the grant check.** Not just every directory before descending: the
///   lister filters files by the extension of the *link*, so `report.xlsx → /etc/passwd` is a row
///   it will hand back with a path outside the workspace. At depth one, drawn in a sidebar the
///   user opened, that is a symlink the user can see in the Finder. Handed to an agent as a
///   discovered file it is a path the tools would then refuse anyway, so it is dropped here and
///   counted in ``WalkResult/skippedProtectedCount`` instead of named.
/// - **Descent is keyed on canonical paths.** A folder is opened once however many symlinks point
///   at it, so `loop → .` terminates instead of running to the depth cap, and a granted tree with
///   two aliases to one folder is not walked twice. Canonicalisation is the lister's, so the
///   identity here is the same string the grant check and the tab strip use.
///
/// Synchronous and `nonisolated` like the lister it drives: the caller hops off the main actor
/// itself, and an `async` signature would put a suspension point in front of the grant check and
/// buy nothing.
public struct DirectoryWalker: Sendable {
    private let lister: DirectoryLister

    /// The boundary, again. Held beside the lister rather than reached through it because the walk
    /// has to check entries it is *not* about to list — a file, or a directory it will decline to
    /// descend — and `DirectoryLister` keeps its own grants private.
    ///
    /// The same instance as the lister's, which is what the one public initialiser makes easy to
    /// get right: two boundaries can disagree, and the loose one would be the one that answered.
    private let grants: WorkspaceGrants

    public init(lister: DirectoryLister, grants: WorkspaceGrants) {
        self.lister = lister
        self.grants = grants
    }

    /// Walks `root`, breadth-first, within every budget.
    ///
    /// - Parameters:
    ///   - root: any spelling of an absolute path inside an active grant.
    ///   - fileExtensions: lowercase, without the dot — ``SpreadsheetFileTypes/listable`` for the
    ///     set the Files panel shows. Directories are always kept; files that do not match are
    ///     dropped, exactly as in ``DirectoryLister/list(_:fileExtensions:limit:)``.
    ///   - entryBudget: how many entries may be returned, clamped into
    ///     `1 ... DirectoryLimits.searchEntryBudget`. Clamping is silent because
    ///     ``WalkResult/truncated`` already tells the truth about what was dropped.
    ///   - directoryBudget: how many folders may be opened, clamped into
    ///     `1 ... DirectoryLimits.searchDirectoryBudget`.
    ///   - maxDepth: how deep it may go, clamped into `1 ... DirectoryLimits.maximumDepth`.
    /// - Throws: whatever the grant check throws **for the root only** —
    ///   `SheetError.pathOutsideWorkspace` or `SheetError.pathDenyListed`. A caller asking about a
    ///   folder it may not read gets a refusal, not an empty tree with a skip count, because those
    ///   two are different answers and only one of them tells the user to grant the folder.
    ///   Refusals *inside* the walk are data: see ``WalkResult/skippedProtectedCount``.
    public nonisolated func walk(
        root: String,
        fileExtensions: Set<String>,
        entryBudget: Int = DirectoryLimits.searchEntryBudget,
        directoryBudget: Int = DirectoryLimits.searchDirectoryBudget,
        maxDepth: Int = DirectoryLimits.maximumDepth
    ) throws(SheetError) -> WalkResult {
        // The root's listing is fetched outside the loop precisely so its grant failure can
        // propagate while every later one is counted.
        let first = try lister.list(root, fileExtensions: fileExtensions, limit: DirectoryLimits.maximumPageSize)
        var walk = Walk(
            grants: grants,
            fileExtensions: fileExtensions,
            entryCap: min(max(entryBudget, 1), DirectoryLimits.searchEntryBudget),
            directoryCap: min(max(directoryBudget, 1), DirectoryLimits.searchDirectoryBudget),
            depthCap: min(max(maxDepth, 1), DirectoryLimits.maximumDepth),
            root: first.path
        )
        var head = 1
        var running = walk.absorb(first, at: Node(path: first.path, relativePath: "", depth: 0))
        while running, head < walk.queue.count {
            let node = walk.queue[head]
            head += 1
            guard walk.directoriesOpened < walk.directoryCap else {
                walk.stop(at: .directories)
                break
            }
            do {
                let listing = try lister.list(
                    node.path,
                    fileExtensions: fileExtensions,
                    limit: DirectoryLimits.maximumPageSize
                )
                walk.directoriesOpened += 1
                running = walk.absorb(listing, at: node)
            } catch {
                // The folder passed the check when it was discovered and fails it now: a grant
                // revoked mid-walk, or a symlink retargeted underneath us. Counted, not thrown —
                // the rest of the tree is still a true answer.
                walk.result.skippedProtectedCount += 1
            }
        }
        return walk.result
    }

    /// A folder waiting to be opened.
    private struct Node {
        var path: String
        var relativePath: String
        var depth: Int
    }

    /// The mutable half of a walk, kept together so that `walk(root:…)` above reads as the
    /// traversal and nothing else.
    private struct Walk {
        let grants: WorkspaceGrants
        let fileExtensions: Set<String>
        let entryCap: Int
        let directoryCap: Int
        let depthCap: Int

        var result: WalkResult
        var queue: [Node]
        /// The root counts as opened, because it was.
        var directoriesOpened = 1
        /// Canonical paths already queued. Seeded with the root so a link back to it is a row and
        /// not a second traversal.
        var visited: Set<String>

        init(
            grants: WorkspaceGrants,
            fileExtensions: Set<String>,
            entryCap: Int,
            directoryCap: Int,
            depthCap: Int,
            root: String
        ) {
            self.grants = grants
            self.fileExtensions = fileExtensions
            self.entryCap = entryCap
            self.directoryCap = directoryCap
            self.depthCap = depthCap
            result = WalkResult(root: root)
            queue = [Node(path: root, relativePath: "", depth: 0)]
            visited = [root]
        }

        /// Folds one folder's listing into the result. Returns `false` when the entry budget ran
        /// out and the walk is over.
        mutating func absorb(_ listing: DirectoryListing, at node: Node) -> Bool {
            guard listing.isReadable else {
                result.unreadableCount += 1
                return true
            }
            if listing.omittedCount > 0 {
                result.omittedCount += listing.omittedCount
                result.truncated = true
            }

            for entry in listing.entries {
                guard result.entries.count < entryCap else {
                    stop(at: .entries)
                    return false
                }
                // Every entry, file or folder: see the type's doc comment for why a file needs
                // this as much as a directory does.
                guard grants.isAllowed(entry.path) else {
                    result.skippedProtectedCount += 1
                    continue
                }
                let relative = node.relativePath.isEmpty
                    ? entry.name
                    : node.relativePath + "/" + entry.name
                result.entries.append(WalkEntry(entry: entry, depth: node.depth + 1, relativePath: relative))

                guard entry.isDirectory else { continue }
                guard node.depth + 1 < depthCap else {
                    result.truncated = true
                    if result.stoppedBy == nil { result.stoppedBy = .depth }
                    continue
                }
                guard visited.insert(entry.path).inserted else { continue }
                queue.append(Node(path: entry.path, relativePath: relative, depth: node.depth + 1))
            }
            return true
        }

        /// Records the budget that ended the walk. Unconditional, unlike the depth note: a walk
        /// that aborted says so even if a branch had already been pruned.
        mutating func stop(at limit: WalkLimit) {
            result.truncated = true
            result.stoppedBy = limit
        }
    }
}
