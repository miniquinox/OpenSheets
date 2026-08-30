/// One node of the workspace tree, as the model holds it.
///
/// **Flat on purpose: there is no `children` array.** A recursive value type would make the
/// synthesised `Hashable` conformance walk the whole subtree on every comparison — quadratic in
/// the size of a folder somebody granted without thinking — and it would force the view to
/// re-flatten the tree on every frame to draw a list. Depth is a number, the order is the array,
/// and both are already what the renderer wants.
///
/// This is the model-side twin of `GlassUI.FileExplorerRow`. They are deliberately not the same
/// type: this one keeps a byte count the app layer still has to format, and it knows nothing
/// about the note rows the explorer inserts.
public struct WorkspaceNode: Sendable, Hashable, Identifiable {
    /// What the node is. There is no `file` subdivision here — whether a file is a workbook or a
    /// delimited text is a presentation question, answered from the extension one layer up.
    public enum Kind: Sendable, Hashable { case root, folder, file }

    /// What we know about this node's contents right now.
    ///
    /// Lazy loading is the whole design, so "we have not looked yet" and "we looked and it is
    /// empty" have to be different values. Collapsing them would make an unexpanded folder
    /// indistinguishable from an empty one.
    public enum Load: Sendable, Hashable {
        /// Never listed. The state every folder starts in, and the reason granting `~` is cheap.
        case idle
        /// A listing is in flight.
        case loading
        /// Listed. `omitted` is how many entries the page cap dropped, carried all the way to the
        /// view so it can say so — a truncated folder that does not admit it is a folder the user
        /// will swear is missing a file.
        case loaded(omitted: Int)
        /// Inside the grant, but the OS would not open it. A normal thing to draw, not an error:
        /// almost every granted folder has one of these in it somewhere.
        case unreadable
        /// It was here and now it is not.
        ///
        /// This exists because the tree outlives the disk. Between listing a folder and clicking
        /// a row in it, a file can be renamed, unmounted, or moved to the Trash by the agent this
        /// app exists to watch. Dropping the row on the spot moves everything under the pointer;
        /// keeping it and marking it dead says what happened.
        case missing
    }

    /// Canonical absolute path.
    public var id: String

    /// The last path component. A root shows the granted folder's name, not its whole path.
    public var name: String

    /// 0 for a root.
    public var depth: Int

    public var kind: Kind

    public var load: Load

    public var isExpanded: Bool

    /// `nil` for folders and whenever the stat failed — the lister never guesses, and neither
    /// does this.
    public var byteCount: Int64?

    public init(
        id: String,
        name: String,
        depth: Int,
        kind: Kind,
        load: Load = .idle,
        isExpanded: Bool = false,
        byteCount: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.depth = depth
        self.kind = kind
        self.load = load
        self.isExpanded = isExpanded
        self.byteCount = byteCount
    }
}

/// Where the expansion set is remembered. A protocol so the tree is testable without SQLite.
///
/// Deliberately synchronous and deliberately tiny: this is a handful of path strings read once at
/// launch and written when a triangle turns. Making it `async` would put an `await` in the middle
/// of a keystroke-rate interaction to save nothing.
public protocol WorkspaceTreeStorage: Sendable {
    func expandedPaths() -> [String]
    func setExpandedPaths(_ paths: [String])
}
