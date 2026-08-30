import Testing

@testable import GlassUI

/// The explorer's value types, before there is anything to look at.
///
/// Three agents build against these in the same wave, so the point of this suite is less "does it
/// work" than "does it still say the same thing tomorrow". Every assertion here is on a pure
/// property — a symbol name, a predicate, a spoken label — which is exactly the kind of logic that
/// gets quietly rewritten inside a `@ViewBuilder` where no test can reach it.
@Suite("File explorer model")
struct FileExplorerModelTests {
    // MARK: - Kind

    @Test("Every kind has its own symbol")
    func kindsHaveDistinctSymbols() {
        let symbols = FileExplorerRow.Kind.allCases.map(\.symbolName)
        #expect(symbols.allSatisfy { !$0.isEmpty })
        #expect(Set(symbols).count == FileExplorerRow.Kind.allCases.count, "two kinds share a symbol: \(symbols)")
    }

    @Test("Exactly the container kinds expand")
    func onlyContainersExpand() {
        let expandable = FileExplorerRow.Kind.allCases.filter(\.isExpandable)
        #expect(Set(expandable) == [.root, .folder])
    }

    @Test("Exactly the file kinds open")
    func onlyFilesOpen() {
        let openable = FileExplorerRow.Kind.allCases.filter(\.isOpenable)
        #expect(Set(openable) == [.workbook, .delimited])
    }

    @Test("Nothing is both expandable and openable")
    func expandingAndOpeningAreDisjoint() {
        // A row has one meaning per click. If a kind ever answered yes to both, the view would
        // have to invent a rule about which one wins, and it would invent a different one to the
        // context menu.
        for kind in FileExplorerRow.Kind.allCases {
            #expect(!(kind.isExpandable && kind.isOpenable), "\(kind) claims both")
        }
    }

    // MARK: - Interactivity

    @Test("A note is never clickable")
    func notesAreInert() {
        let note = FileExplorerRow(id: "note:/Users/x/Reports", name: "+ 2,609 more", depth: 1, kind: .note)
        #expect(!note.isInteractive)
    }

    @Test("A vanished file is never clickable")
    func missingRowsAreInert() {
        let gone = FileExplorerRow(
            id: "/Users/x/Reports/q3.xlsx",
            name: "q3.xlsx",
            depth: 2,
            kind: .workbook,
            load: .missing
        )
        #expect(!gone.isInteractive)
        #expect(FileExplorerRow(id: gone.id, name: gone.name, depth: 2, kind: .workbook).isInteractive)
    }

    @Test("Unreadable is still selectable")
    func unreadableRowsStayInteractive() {
        // Unreadable is a fact about a folder's contents, not about the row. Reveal in Finder and
        // "remove this root" both have to keep working on it, so the row stays live.
        let locked = FileExplorerRow(id: "/Users/x/.Trash", name: ".Trash", depth: 1, kind: .folder, load: .unreadable)
        #expect(locked.isInteractive)
    }

    // MARK: - Accessibility

    @Test("A collapsed folder says it is a collapsed folder")
    func collapsedFolderIsSpoken() {
        let row = FileExplorerRow(id: "/Users/x/Outreach", name: "Outreach", depth: 1, kind: .folder)
        let label = row.accessibilityLabel
        #expect(label.contains("Outreach"))
        #expect(label.contains("folder"))
        #expect(label.contains("collapsed"))
        #expect(!label.contains("expanded"))
    }

    @Test("Expansion, kind, trouble and detail are all spoken, in that order")
    func labelOrderIsFixed() {
        let row = FileExplorerRow(
            id: "/Users/x/Archive",
            name: "Archive",
            detail: "4 items",
            depth: 0,
            kind: .root,
            isExpanded: true,
            load: .unreadable
        )
        #expect(row.accessibilityLabel == "Archive, folder, expanded, not readable, 4 items")
    }

    @Test("Files are named by what they are, not by their symbol")
    func fileKindsAreSpoken() {
        let book = FileExplorerRow(
            id: "/x/budget.xlsx",
            name: "budget.xlsx",
            detail: "12 KB",
            depth: 1,
            kind: .workbook
        )
        #expect(book.accessibilityLabel == "budget.xlsx, spreadsheet, 12 KB")

        let text = FileExplorerRow(id: "/x/rows.csv", name: "rows.csv", depth: 1, kind: .delimited, load: .missing)
        #expect(text.accessibilityLabel == "rows.csv, delimited text, missing")
    }

    @Test("A note reads as its own sentence")
    func noteLabelHasNoKindSuffix() {
        // "+ 2,609 more, folder" would be nonsense, and a note is the one row whose name is
        // already a whole sentence.
        let note = FileExplorerRow(id: "note:/x", name: "Nothing to open here.", depth: 1, kind: .note)
        #expect(note.accessibilityLabel == "Nothing to open here.")
    }

    // MARK: - State

    @Test("An empty state is empty regardless of what else it carries")
    func emptinessIsAboutRows() {
        let searching = FileExplorerState(search: "budget", isSearching: true, emptyMessage: "No matches.")
        #expect(searching.isEmpty)

        let listed = FileExplorerState(rows: [
            FileExplorerRow(id: "/x", name: "x", depth: 0, kind: .root),
        ])
        #expect(!listed.isEmpty)
    }

    @Test("The defaults are the launcher's, not the sidebar's")
    func defaultStateOffersAddFolder() {
        // E5 hosts this in the launcher, where granting is the primary action; E6 turns it off in
        // the sidebar. Pinning the default stops the two hosts drifting apart silently.
        let state = FileExplorerState()
        #expect(state.offersAddFolder)
        #expect(state.search.isEmpty)
        #expect(!state.isSearching)
        #expect(state.searchNote == nil)
        #expect(state.emptyMessage == nil)
    }

    @Test("Rows are equatable by value, so a redraw is a diff")
    func rowsCompareByValue() {
        let base = FileExplorerRow(id: "/x/a.csv", name: "a.csv", depth: 1, kind: .delimited)
        var selected = base
        selected.isSelected = true
        #expect(base != selected)
        #expect(base == FileExplorerRow(id: "/x/a.csv", name: "a.csv", depth: 1, kind: .delimited))
    }
}
