/// One line of the file explorer, already resolved.
///
/// Flat, not a tree. The row carries its own ``depth`` and the view multiplies it by an indent —
/// the same trade the tab strip makes, for the same reason: `GlassUI` draws what it is told and
/// knows nothing about grants, canonical paths, or what is on disk. The app layer answers all of
/// that and hands down strings, which is what keeps this previewable and keeps `GlassUI` free of
/// a `DocumentCore` import.
public struct FileExplorerRow: Sendable, Hashable, Identifiable {
    /// What the row is, which decides its symbol and what a click on it means.
    public enum Kind: Sendable, Hashable, CaseIterable {
        case root, folder, workbook, delimited, note
        /// `note` is the "+ 2,609 more" / "Nothing to open here." row: not a file, not clickable.
        ///
        /// It is a row rather than a footer because it has to sit at the depth of the folder it
        /// is talking about. A truncated listing and an empty one are facts about one branch, and
        /// a message that floats free of that branch is a message about the wrong thing.

        /// SF Symbol. Pure, and therefore tested — the same reason `FileTabDot` was extracted out
        /// of its view (`Chrome/FileTabStrip.swift:101`).
        public var symbolName: String {
            switch self {
            case .root: "folder.badge.gearshape"
            case .folder: "folder"
            case .workbook: "tablecells"
            case .delimited: "doc.plaintext"
            case .note: "ellipsis"
            }
        }

        public var isExpandable: Bool { self == .root || self == .folder }

        public var isOpenable: Bool { self == .workbook || self == .delimited }
    }

    /// How much is known about the row's children, or about the row itself.
    public enum Load: Sendable, Hashable {
        case idle, loading, unreadable, missing
    }

    /// The canonical path, or `"note:<parent path>"` for a `.note` row.
    public var id: String

    /// The file or folder name as it should be read aloud and drawn. Extension included.
    public var name: String

    /// Right-aligned trailing text, already formatted by the app layer: "12 KB", "+ 2,609 more".
    public var detail: String?

    /// How many levels below its root the row sits. `0` is a root.
    public var depth: Int

    public var kind: Kind

    public var isExpanded: Bool

    public var load: Load

    public var isSelected: Bool

    public init(
        id: String,
        name: String,
        detail: String? = nil,
        depth: Int,
        kind: Kind,
        isExpanded: Bool = false,
        load: Load = .idle,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.depth = depth
        self.kind = kind
        self.isExpanded = isExpanded
        self.load = load
        self.isSelected = isSelected
    }

    /// Whether a click on this row should do anything at all.
    ///
    /// Two rows look like files and are not: the note, which is a sentence, and a row whose file
    /// has since gone. Both stay visible — the note because it is the answer, the missing row
    /// because deleting it out from under a pointer is worse than greying it out.
    public var isInteractive: Bool { kind != .note && load != .missing }

    /// What VoiceOver reads.
    ///
    /// Everything the row says with position, indentation, a symbol or a disclosure triangle gets
    /// said again in words here, because none of those four channels is available to somebody
    /// listening to this list. The order is fixed — name, kind, expansion, trouble, detail — so
    /// that a run of rows reads as a list rather than as a paragraph.
    public var accessibilityLabel: String {
        var label = name
        switch kind {
        case .root, .folder: label += ", folder"
        case .workbook: label += ", spreadsheet"
        case .delimited: label += ", delimited text"
        case .note: break
        }
        if kind.isExpandable {
            label += isExpanded ? ", expanded" : ", collapsed"
        }
        switch load {
        case .unreadable: label += ", not readable"
        case .missing: label += ", missing"
        case .idle, .loading: break
        }
        if let detail { label += ", \(detail)" }
        return label
    }
}

/// Everything the explorer draws, in one value.
///
/// Already flattened and already filtered: by the time this arrives, the decisions about what is
/// expanded, what matched the search and what got truncated have all been made.
public struct FileExplorerState: Sendable, Hashable {
    /// Already flattened, in display order. The view does no tree walking.
    public var rows: [FileExplorerRow]

    public var search: String

    /// True while a search is still walking the disk. Distinct from "no results": a spinner and
    /// an empty state are opposite claims, and showing the second one early is a lie the user
    /// acts on by giving up.
    public var isSearching: Bool

    /// "Stopped after 20,000 files — narrow the search or open a subfolder."
    public var searchNote: String?

    /// Shown instead of `rows` when it is non-nil and `rows` is empty.
    public var emptyMessage: String?

    /// Whether to draw the `+` in the header. False in the sidebar, where granting lives in the
    /// Claude panel already.
    /// A button drawn under ``emptyMessage``, or `nil` for a message with no action.
    ///
    /// The empty state here is not "nothing matched" — it is "you have not opened a folder yet",
    /// which is a state with an obvious next move. A sentence that names the move without offering
    /// it makes the user go hunting for the control it just described.
    public var emptyActionLabel: String?

    /// A row to bring into view when this changes.
    ///
    /// Opening a folder puts it in a list that is already taller than the section — the first
    /// folder, expanded, fills the height on its own — so the one you just opened arrives below
    /// the fold and nothing appears to have happened. The host names the row; the list scrolls to
    /// it only when the value changes, so it never fights the user's own scrolling.
    public var scrollTarget: String?

    public var offersAddFolder: Bool

    public init(
        rows: [FileExplorerRow] = [],
        search: String = "",
        isSearching: Bool = false,
        searchNote: String? = nil,
        emptyMessage: String? = nil,
        emptyActionLabel: String? = nil,
        scrollTarget: String? = nil,
        offersAddFolder: Bool = true
    ) {
        self.rows = rows
        self.search = search
        self.isSearching = isSearching
        self.searchNote = searchNote
        self.emptyMessage = emptyMessage
        self.emptyActionLabel = emptyActionLabel
        self.scrollTarget = scrollTarget
        self.offersAddFolder = offersAddFolder
    }

    public var isEmpty: Bool { rows.isEmpty }
}

/// What the explorer reports upwards. Value in, action closure out — the explorer performs none
/// of these itself, because every one of them needs something `GlassUI` is not allowed to hold:
/// a store, a grant, a window, or `NSWorkspace`.
public enum FileExplorerAction: Sendable, Hashable {
    case toggle(String)
    case open(String)
    case select(String)
    case refresh(String)
    case revealInFinder(String)
    case removeRoot(String)
    case addFolder
    case search(String)
}
