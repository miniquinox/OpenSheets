import Foundation
import SheetModel

/// One line of a directory listing: a file that could be opened, or a folder that could be
/// descended into.
///
/// A string, not a `URL`, and that is the whole point. Canonicalisation happens once, in the
/// lister, at the same moment the grant is checked — so the path in an entry is a path the user
/// has already granted, spelled the one way this app spells it. Everything above keys on that
/// string. A layer that built its own `URL` from a name and a parent could build one pointing at
/// `../../.ssh`, and then the grant check would be a thing that happened earlier rather than a
/// thing that is true.
public struct DirectoryEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }

    /// Canonical absolute path. The identity everything keys on, produced by the lister — never
    /// by the caller, and never by the view.
    public var path: String

    /// The last path component, extension included. `budget.xlsx`, not `budget`: this app's
    /// premise is that the file on disk is the API, so half a name is half an answer.
    public var name: String

    public var isDirectory: Bool

    /// `nil` for directories and whenever the stat failed. Never a guess.
    ///
    /// The two `nil`s are deliberate and mean the same thing: we do not know. A folder's size is
    /// a question with several defensible answers and no cheap one, and a stat that failed is not
    /// a zero-byte file. This number is drawn next to a file name, where it reads as fact, so the
    /// only honest thing to render when it is unknown is nothing at all.
    public var byteCount: Int64?

    /// Modification time, or `nil` when the stat failed. Same rule as ``byteCount``.
    public var modifiedAt: Date?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

/// What one directory holds, one level deep, as far as we were allowed and willing to look.
///
/// Both of the ways this answer can be incomplete are fields on it rather than errors thrown out
/// of it, because both are ordinary. Directories are big and some of them do not open; a tree
/// that aborted on either would be a tree that stops working on a real machine.
public struct DirectoryListing: Sendable, Hashable {
    /// The canonical path that was listed. Present so a listing that arrives late can be matched
    /// to the row that asked for it — by then the selection may have moved on.
    public var path: String

    /// Directories first, then files; within each, case- and diacritic-insensitive by name.
    ///
    /// Sorted here rather than in the view: the order is part of the answer, every consumer wants
    /// the same one, and a comparator living in a `ForEach` is a comparator no test can reach.
    public var entries: [DirectoryEntry]

    /// How many entries the page cap dropped. Surfaced, never swallowed — a list that silently
    /// stops at 500 is a list that lies about what is in the folder.
    ///
    /// It exists so the layer above can draw a row saying so. The alternative — truncating
    /// quietly — produces the worst possible bug report, which is a person certain that a file
    /// they are looking at in Finder does not exist.
    public var omittedCount: Int

    /// False when the directory could not be read at all. Not an error: a folder inside a grant
    /// that the OS will not open is a normal thing to draw, not a thing to abort on.
    ///
    /// A granted folder routinely contains one of these — a `.Trash`, a sandbox container, a
    /// network mount that is not mounted right now. The user asked to see the folder, so the
    /// folder is what they get, with one branch of it marked as closed.
    public var isReadable: Bool

    /// The listing for a permitted directory that would not open.
    ///
    /// Spelled as a stored closure so it can be handed to a lister as a value. It is
    /// `@Sendable` because a `static let` has to be `Sendable` in Swift 6 mode and a plain
    /// function type is not — the annotation is a compiler requirement, not a design statement.
    public static let unreadable: @Sendable (String) -> DirectoryListing = { path in
        DirectoryListing(path: path, entries: [], omittedCount: 0, isReadable: false)
    }

    public init(path: String, entries: [DirectoryEntry], omittedCount: Int = 0, isReadable: Bool = true) {
        self.path = path
        self.entries = entries
        self.omittedCount = omittedCount
        self.isReadable = isReadable
    }
}

/// One directory, one level, already inside the grant boundary.
///
/// A protocol so `DocumentCore` can be tested against a fake without a filesystem, and so the
/// only implementation that touches the disk stays in the module that owns grant enforcement.
///
/// Note what is *not* here: no recursion, no watching, no search. A caller that wants a tree asks
/// for one directory at a time and keeps its own shape, which is what makes the budgets in
/// ``DirectoryLimits`` enforceable rather than advisory.
public protocol DirectoryListingSource: Sendable {
    /// - Parameter fileExtensions: lowercase, without the dot. Files not matching are omitted;
    ///   directories are always included.
    /// - Throws: `SheetError.pathOutsideWorkspace` when `path` is not inside an active grant or is
    ///   deny-listed. An unreadable-but-permitted directory returns `isReadable: false` instead.
    func list(
        _ path: String,
        fileExtensions: Set<String>,
        limit: Int
    ) throws(SheetError) -> DirectoryListing
}

/// Budgets. Named constants rather than `Limits` entries because `SheetModel` is frozen.
///
/// Every number here was measured on a real home directory rather than picked for looking round.
/// They are the difference between a file tree and a way to hang the app on someone's Downloads
/// folder.
public enum DirectoryLimits {
    /// Entries per directory before `omittedCount` starts counting. `~/Downloads` holds 3,109 in
    /// its top level alone, so this is a real ceiling and not a theoretical one.
    public static let pageSize = 500

    /// Hard clamp on any caller-supplied limit.
    public static let maximumPageSize = 5000

    /// Files a search may visit before it stops and says so.
    public static let searchEntryBudget = 20_000

    /// Directories a search may open before it stops and says so. `~/Documents` holds 77,024.
    public static let searchDirectoryBudget = 2000

    /// How deep the tree may go. A symlink loop that survives canonicalisation still terminates.
    public static let maximumDepth = 12
}
