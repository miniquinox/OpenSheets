import DocumentCore
import Foundation
import GlassUI

/// The explorer's state mapping: ``DocumentCore/WorkspaceTree`` in, ``GlassUI/FileExplorerState``
/// out.
///
/// The twin of ``WorkspaceState``, and here for the same reason. `GlassUI` may not import
/// `DocumentCore` and may never see a `URL`, so somebody has to translate; doing it in one enum of
/// pure functions rather than inline in two hosts is what stops the launcher rail and the sidebar
/// section from quietly becoming two different components.
///
/// **Everything a human reads is formatted here** — the byte count, the truncation count, the
/// sentence an empty folder gets, the folder a search hit came from. That is the division
/// ``SidebarColumn`` already makes, and it is why the view can be previewed from a fixture with
/// no filesystem behind it.
///
/// `@MainActor` because ``DocumentCore/WorkspaceTree`` is: reading its `nodes` from here is what
/// registers the SwiftUI dependency that redraws the rail when a listing lands.
@MainActor
enum WorkspaceExplorerState {
    // MARK: - The whole rail

    /// Everything the explorer draws, from the tree and the host's two decisions.
    ///
    /// - Parameters:
    ///   - selection: the row to light up — the file the window is showing, or the last one
    ///     clicked. `nil` in a launcher that has not opened anything yet.
    ///   - offersAddFolder: whether this host draws the `+`. The sidebar does not: granting
    ///     already lives in its Claude panel, and two buttons for one action in one column is one
    ///     too many.
    static func explorer(
        for tree: WorkspaceTree,
        selection: String?,
        offersAddFolder: Bool
    ) -> FileExplorerState {
        // Read before the branch so both paths depend on it, and so a query of nothing but
        // spaces takes the tree path — which is what `WorkspaceTree` itself does with it.
        let query = tree.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            return searching(tree, selection: selection, offersAddFolder: offersAddFolder)
        }
        let scoped = openFolders(in: tree)
        return FileExplorerState(
            rows: rows(for: scoped, selection: selection),
            search: tree.search,
            isSearching: tree.isSearching,
            searchNote: nil,
            // Not "no folders yet" — there may be a dozen granted. The question this section
            // answers is "which folder am I in", and the answer is none.
            emptyMessage: scoped.isEmpty ? "No folder open." : nil,
            emptyActionLabel: scoped.isEmpty ? "Open Folder…" : nil,
            // The folder opened most recently. It is last in the list and the list is taller than
            // the section — one expanded folder fills the height by itself — so without this the
            // folder the user just chose arrives off-screen and the click reads as a no-op.
            scrollTarget: tree.pinnedRoots.last,
            offersAddFolder: offersAddFolder
        )
    }

    /// The open folders' subtrees, and nothing else.
    ///
    /// A grant and an open folder are two different things, and showing the first is what made
    /// this section useless: every folder the user had ever granted, listed together, so the one
    /// they had just opened was a row among fifteen. A grant says *Claude may read here*; it is a
    /// standing permission, and there can be many. An open folder is *what I am working in* — one
    /// at a time, chosen deliberately, and the only thing a file tree should be showing.
    ///
    /// ``DocumentCore/WorkspaceTree`` puts the pinned roots first, in the order they were opened,
    /// each followed by its own descendants — so the scope is the prefix covering that many
    /// depth-0 rows. Empty when none is open, which is the "Open Folder…" state, not an error.
    static func openFolders(in tree: WorkspaceTree) -> [WorkspaceNode] {
        let count = tree.pinnedRoots.count
        guard count > 0 else { return [] }
        // The pinned block is a prefix of `nodes`: each open folder at depth 0, in the order the
        // user opened them, each followed by its own subtree. So the scope ends at the depth-0
        // row after the last one, and counting depth-0 rows is enough to find it.
        var scoped: [WorkspaceNode] = []
        var roots = 0
        for node in tree.nodes {
            if node.depth == 0 {
                roots += 1
                if roots > count { break }
            }
            scoped.append(node)
        }
        return scoped
    }

    // MARK: - The tree

    /// The tree's flat nodes plus the note rows that explain them.
    ///
    /// The notes are the only thing added here, and they are why this is not a `map`. A note
    /// belongs *after* everything its folder contains, which in a flattened array is not the next
    /// index — it is wherever the subtree ends. So each note is parked with the depth of the
    /// folder that owns it and emitted by the first row that is not one of its descendants.
    static func rows(for nodes: [WorkspaceNode], selection: String?) -> [FileExplorerRow] {
        var rows: [FileExplorerRow] = []
        /// Owner depth and note, outermost first. A stack, because folders nest.
        var pending: [(depth: Int, note: FileExplorerRow)] = []
        /// Paths already emitted. An open folder is a top-level row *and* still lives inside
        /// whatever contains it, so opening two nested folders — or expanding one down to the
        /// other — reaches the same directory twice. `FileExplorer` renders `ForEach` over
        /// `Identifiable`, and two rows sharing an id is not cosmetic: SwiftUI picks one
        /// arbitrarily for state and animates the other into the wrong place.
        var seen: Set<String> = []
        /// The open folders, by id. A duplicate is resolved in favour of the depth-0 copy even
        /// when the buried one comes first in the array: the row the user opened deliberately is
        /// the one they are looking for, and demoting it to a child of something else is how a
        /// folder they just opened goes missing — the bug this whole feature exists to remove.
        let openFolders = Set(nodes.lazy.filter { $0.depth == 0 }.map(\.id))
        var skippingBelow: Int?

        for (index, node) in nodes.enumerated() {
            if let depth = skippingBelow {
                if node.depth > depth { continue }
                skippingBelow = nil
            }
            if node.depth > 0, openFolders.contains(node.id) {
                skippingBelow = node.depth
                continue
            }
            guard seen.insert(node.id).inserted else {
                skippingBelow = node.depth
                continue
            }
            while let last = pending.last, node.depth <= last.depth {
                rows.append(last.note)
                pending.removeLast()
            }
            rows.append(row(node, isSelected: node.id == selection))
            let next = nodes.indices.contains(index + 1) ? nodes[index + 1] : nil
            if let note = note(for: node, hasChildren: (next?.depth ?? node.depth) > node.depth) {
                pending.append((depth: node.depth, note: note))
            }
        }
        while let last = pending.popLast() { rows.append(last.note) }
        return rows
    }

    /// One tree row.
    static func row(_ node: WorkspaceNode, isSelected: Bool) -> FileExplorerRow {
        FileExplorerRow(
            id: node.id,
            name: node.name,
            detail: detail(node),
            depth: node.depth,
            kind: kind(node),
            isExpanded: node.isExpanded,
            load: load(node),
            isSelected: isSelected
        )
    }

    /// The dimmed line under a folder's children: what the page cap dropped, or that there was
    /// nothing to drop.
    ///
    /// Both halves are the same promise. A directory listing capped at 500 that does not say so is
    /// a listing the user will swear lost a file, and an expanded folder that draws nothing at all
    /// is indistinguishable from one that is still loading. `nil` for everything else — a folder
    /// with children and nothing omitted has nothing to add.
    static func note(for node: WorkspaceNode, hasChildren: Bool) -> FileExplorerRow? {
        guard node.isExpanded, node.kind != .file, case let .loaded(omitted) = node.load
        else { return nil }
        let text: String
        if omitted > 0 {
            text = "+ \(omitted.formatted()) more"
        } else if hasChildren {
            return nil
        } else {
            text = "Nothing to open here."
        }
        return FileExplorerRow(
            id: "note:\(node.id)",
            name: text,
            depth: node.depth + 1,
            kind: .note
        )
    }

    // MARK: - Node to row

    /// `.xlsx` gets a table glyph and `.csv` a text one, which is the only reason the view needs
    /// two file kinds at all. Read off the **name**, not the path, so a folder called `data.csv`
    /// cannot be mistaken for a file — `node.kind` has already settled that question.
    static func kind(_ node: WorkspaceNode) -> FileExplorerRow.Kind {
        switch node.kind {
        case .root: .root
        case .folder: .folder
        case .file:
            DocumentWorkbookReader.workbookExtensions.contains(fileExtension(of: node.name))
                ? .workbook
                : .delimited
        }
    }

    /// The tree's five load states as the view's four.
    ///
    /// `.loaded` collapses into `.idle` deliberately: to a *row*, a folder that has been listed
    /// and one that has never been asked look the same — a name and a triangle. What the listing
    /// found is said by the rows underneath it and by ``note(for:hasChildren:)``, not by the
    /// folder's own line.
    static func load(_ node: WorkspaceNode) -> FileExplorerRow.Load {
        switch node.load {
        case .idle, .loaded: .idle
        case .loading: .loading
        case .unreadable: .unreadable
        case .missing: .missing
        }
    }

    /// "12 KB", and nothing for a folder.
    ///
    /// A folder's size is either a lie or a subtree walk, and this design does neither: the whole
    /// point of listing one level at a time is that nothing here knows what is further down.
    static func detail(_ node: WorkspaceNode) -> String? {
        guard node.kind == .file, let bytes = node.byteCount else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Search

    /// The flat result list that replaces the tree while there is a query.
    ///
    /// Ordered by containing folder and then by name, so hits from one place arrive together —
    /// plan §4.3's grouping, done by sorting rather than by inserting headers. A header row would
    /// have to be a folder the tree does not know about, and clicking its triangle would do
    /// nothing, which is precisely the silence this feature exists to remove.
    private static func searching(
        _ tree: WorkspaceTree,
        selection: String?,
        offersAddFolder: Bool
    ) -> FileExplorerState {
        FileExplorerState(
            rows: ordered(tree.searchResults).map { match in
                searchRow(match, isSelected: match.id == selection)
            },
            search: tree.search,
            isSearching: tree.isSearching,
            searchNote: tree.searchNote,
            emptyMessage: searchEmptyMessage(query: tree.search, isSearching: tree.isSearching),
            offersAddFolder: offersAddFolder
        )
    }

    /// By folder, then by name, both the way Finder sorts.
    static func ordered(_ matches: [WorkspaceNode]) -> [WorkspaceNode] {
        matches.sorted { left, right in
            let leftFolder = parentPath(of: left.id)
            let rightFolder = parentPath(of: right.id)
            guard leftFolder == rightFolder else {
                return leftFolder.localizedStandardCompare(rightFolder) == .orderedAscending
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// A search hit, which wants a different trailing column from a tree row.
    ///
    /// The folder rather than the size: a file you found by expanding folders is already located,
    /// and one pulled out of a walk of two thousand directories is not — *where is it* is the
    /// whole question a flat result list raises. Depth is flattened to zero for the same reason;
    /// indenting results by where they happen to sit would imply a hierarchy that is not on
    /// screen. The full path is still one hover away, in the row's tooltip.
    static func searchRow(_ node: WorkspaceNode, isSelected: Bool) -> FileExplorerRow {
        FileExplorerRow(
            id: node.id,
            name: node.name,
            detail: displayFolder(of: node.id),
            depth: 0,
            kind: kind(node),
            load: load(node),
            isSelected: isSelected
        )
    }

    /// What an empty result list says, or `nil` to say nothing.
    ///
    /// "No spreadsheets match" while the walk is still running is a claim we do not have yet — the
    /// answer may be two thousand directories away, and a user who reads it stops looking. So the
    /// two states get two sentences rather than one.
    static func searchEmptyMessage(query: String, isSearching: Bool) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isSearching ? "Searching…" : "No spreadsheets match \"\(trimmed)\"."
    }

    // MARK: - Paths

    /// The containing directory, as a path. String surgery rather than `URL`, because a `URL`
    /// round trip percent-encodes and re-decodes an id that is already canonical and already the
    /// key everything else compares on.
    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// The containing folder's *name* — the part that fits in a 248pt rail. `~` for a hit sitting
    /// directly in the home folder, and the whole path when there is no last component to take,
    /// which is only ever `/`.
    static func displayFolder(of path: String) -> String {
        let parent = parentPath(of: path)
        guard parent != NSHomeDirectory() else { return "~" }
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty ? parent : name
    }

    /// Lowercased, without the dot, and empty when there is not one.
    static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}
