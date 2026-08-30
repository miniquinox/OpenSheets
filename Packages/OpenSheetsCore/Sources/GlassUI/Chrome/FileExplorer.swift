import SwiftUI

/// The granted folders, as a tree you can click through.
///
/// # It draws no surface
///
/// No glass surface modifier appears anywhere in this file, and no material, and that is the
/// design rather than an omission. The explorer is *content*: in the launcher it sits inside the
/// card that is already there, and in the document window it sits inside the sidebar's vibrant
/// chrome. A lens of its own would be a lens on a lens, which is the one thing the design system
/// is unambiguous about. ``EmptyStateView`` makes the same call for the same reason.
///
/// The consequence worth stating, because it is the part that gets undone by accident: since it
/// asks for no surface tier, it has **no `ComponentCatalog` entry and no snapshot goldens**. Add a
/// surface here and six golden files start disagreeing with the design they describe.
///
/// # It knows nothing about the disk
///
/// Every row arrives resolved — name, depth, kind, whether it is expanded, whether we could read
/// it — and every click leaves as a ``FileExplorerAction``. There is no file manager here, no path
/// arithmetic, and no notion of what a grant is. That is what lets the whole thing be previewed
/// from ``Mock`` and what keeps `GlassUI` free of a `DocumentCore` import.
///
/// # It does no tree walking
///
/// ``FileExplorerState/rows`` is already flat and already in display order. A folder holding three
/// thousand entries is the normal case here (plan §3), so the list is lazy and the app layer caps
/// what it hands over; the view's job is to indent by ``FileExplorerRow/depth`` and stop.
///
/// # Height belongs to the host
///
/// The scroller takes whatever it is given. The launcher rail and the sidebar section want
/// different caps and both of them own that decision, so imposing one here would be a component
/// deciding how big its container is.
public struct FileExplorer: View {
    private let state: FileExplorerState
    private let context: AppearanceContext
    private let title: String
    private let perform: (FileExplorerAction) -> Void

    /// The row under the pointer. Local, and the only mutable state in the component — everything
    /// else is a fact about the workspace and belongs to whoever owns the tree.
    @State private var hovered: String?
    /// Drives `scrollPosition`. Written only by ``FileExplorerState/scrollTarget`` changing, and
    /// read back as the user scrolls, which is what keeps the two from fighting.
    @State private var scrolled: String?

    /// - Parameter title: The section header. Defaulted because the two hosts name the same tree
    ///   differently and both are right: the launcher rail is a list of the folders you have
    ///   granted (plan §4.1, `FOLDERS`), while the sidebar section is one more thing this document
    ///   window can show you (plan §4.2, `FILES`). ``FileExplorerState`` has no field for it and is
    ///   not ours to change, so it rides on the initialiser — additively, so the three-argument
    ///   form the plan fixes still compiles and still says `Folders`.
    public init(
        state: FileExplorerState,
        context: AppearanceContext,
        title: String = "Folders",
        perform: @escaping (FileExplorerAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.title = title
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            content
            if let note = state.searchNote {
                Text(note)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DS.Space.xs) {
            SectionHeader(title)
            if state.offersAddFolder {
                Button { perform(.addFolder) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: Self.headerGlyphSize, weight: .semibold))
                        .frame(width: Self.headerHitTarget, height: Self.headerHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Chrome.secondary)
                .help("Grant a folder…")
                .accessibilityLabel("Grant a folder")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.top, DS.Space.xs)
    }

    // MARK: - Search

    /// A plain field rather than `.searchable`.
    ///
    /// `.searchable` puts the field where the *platform* wants it, which is the toolbar of the
    /// enclosing scene. This one lives in a 248pt rail inside somebody else's window, and it has
    /// to sit directly under its own section header or it stops being about this list.
    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: state.isSearching ? "ellipsis" : "magnifyingglass")
                .font(.system(size: Self.fieldGlyphSize))
                .foregroundStyle(DS.Chrome.secondary)
                .symbolEffect(.pulse, isActive: state.isSearching && !context.reduceMotion)
                .frame(width: Self.glyphColumn)

            TextField(
                "Search",
                text: Binding(
                    get: { state.search },
                    // Guarded, because AppKit's field writes its current contents back through the
                    // binding while it lays out. Unguarded, showing the explorer reports a search
                    // nobody typed — harmless in itself, and a loop waiting to happen the moment
                    // somebody upstream reads `.search` as "the query moved".
                    set: { typed in
                        guard typed != state.search else { return }
                        perform(.search(typed))
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(DS.Text.control)
            .accessibilityLabel("Search spreadsheets")

            if !state.search.isEmpty {
                Button { perform(.search("")) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Chrome.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - The list

    @ViewBuilder
    private var content: some View {
        if state.rows.isEmpty, let message = state.emptyMessage {
            // One quiet line, not an ``EmptyStateView``. That component fills a window and brings
            // a glyph and a headline with it; this is a section inside somebody else's chrome, and
            // the sidebar already answers "this list has nothing in it" exactly this way.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text(message)
                    .font(DS.Text.control)
                    .foregroundStyle(DS.Chrome.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let label = state.emptyActionLabel {
                    Button(label) { perform(.addFolder) }
                        .buttonStyle(.bordered)
                        .font(DS.Text.control)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(.vertical, DS.Space.hair)
                .animation(DS.Motion.snappy, value: state.rows)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition(id: $scrolled, anchor: .top)
            // Only on a *change* of target. Binding the position outright would drag the list
            // back every time anything else re-rendered it, which is the same feeling as a page
            // that will not let you scroll.
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(DS.Motion.snappy) { scrolled = target }
            }
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func rowView(_ row: FileExplorerRow) -> some View {
        if row.kind == .note {
            noteRow(row)
        } else {
            fileRow(row)
        }
    }

    /// A folder, a root, or a file.
    ///
    /// The disclosure triangle is a **sibling** of the row's button rather than a button inside
    /// it. Nesting them would make one click ambiguous — the chevron's job is to expand without
    /// selecting, and a button inside a button cannot promise that. As siblings each owns its own
    /// hit area, and Full Keyboard Access gets the two stops it should have.
    /// Whether this row shows its close control right now.
    ///
    /// Roots only, and only under the pointer. A folder you opened is a thing you can put away,
    /// and burying that in a context menu is how the last four controls in this app went unfound.
    private func showsClose(_ row: FileExplorerRow) -> Bool {
        row.kind == .root && hovered == row.id
    }

    /// The `×` on an open folder's row.
    ///
    /// It replaces the trailing detail rather than sitting beside it, so the row never changes
    /// width on hover — the same reason ``FileTabStrip`` swaps its close button in over the tab's
    /// own trailing space instead of adding to it.
    @ViewBuilder
    private func closeControl(_ row: FileExplorerRow) -> some View {
        if showsClose(row) {
            Button { perform(.closeFolder(row.id)) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Self.closeGlyphSize, weight: .semibold))
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: Self.closeHitTarget, height: Self.closeHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this folder. The grant stays.")
            .accessibilityLabel("Close folder \(row.name)")
        }
    }

    private func fileRow(_ row: FileExplorerRow) -> some View {
        HStack(spacing: 0) {
            // An expression, not a literal, which is what keeps this off the spacing scale
            // honestly: it is a function of the row's depth rather than a number somebody picked.
            Color.clear.frame(width: CGFloat(row.depth) * Self.indentPerLevel)

            disclosure(row)

            Button { activate(row) } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: symbolName(for: row))
                        .font(.system(size: Self.glyphSize))
                        .foregroundStyle(glyphTint(for: row))
                        .frame(width: Self.glyphColumn)

                    Text(row.name)
                        .font(DS.Text.control)
                        .foregroundStyle(DS.Chrome.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: DS.Space.xs)

                    if let detail = row.detail, !showsClose(row) {
                        Text(detail)
                            .dsNumeric(DS.Text.numericCaption)
                            .foregroundStyle(DS.Chrome.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)

            closeControl(row)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .opacity(row.load == .idle || row.load == .loading ? 1 : Self.troubledRowOpacity)
        .background {
            // Selection wins. A hovered row that is also the open one has to keep reading as the
            // open one, or the pointer erases the answer to "which file am I looking at".
            if row.isSelected {
                DS.Radius.shape(DS.Radius.chip).fill(DS.Chrome.selectedRow)
            } else if hovered == row.id {
                DS.Radius.shape(DS.Radius.chip).fill(DS.Chrome.separator)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
        .contextMenu { contextMenu(for: row) }
        .help(helpText(for: row))
    }

    /// "+ 2,609 more" and "Nothing to open here.".
    ///
    /// Not a button, and it takes no hover, because there is nothing behind it to open. It keeps
    /// the indent and the disclosure column of the folder it is talking about so that it reads as
    /// part of that branch rather than as a footer for the whole list.
    ///
    /// Set in tabular figures even when it is a sentence: the note that matters is the truncation
    /// count, and a count that changes width as a directory is re-listed makes the row twitch.
    private func noteRow(_ row: FileExplorerRow) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(row.depth) * Self.indentPerLevel)
            Color.clear.frame(width: Self.chevronColumn)

            HStack(spacing: DS.Space.xs) {
                Image(systemName: row.kind.symbolName)
                    .font(.system(size: Self.glyphSize))
                    .foregroundStyle(DS.Chrome.tertiary)
                    .frame(width: Self.glyphColumn)

                if !row.name.isEmpty {
                    Text(row.name)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.Space.xs)

                if let detail = row.detail {
                    Text(detail)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    /// The chevron column: a triangle, a spinner, or nothing — always the same width.
    ///
    /// The width is held in all four states on purpose. A folder that shifts its name sideways the
    /// moment it starts listing is the cheapest-looking thing a file tree can do, and it happens
    /// exactly when the user is watching, because they just clicked it.
    private func disclosure(_ row: FileExplorerRow) -> some View {
        Group {
            switch row.load {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(Self.spinnerScale)
                    .accessibilityHidden(true)
            case .idle where row.kind.isExpandable:
                Button { perform(.toggle(row.id)) } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: Self.chevronGlyphSize, weight: .semibold))
                        .foregroundStyle(DS.Chrome.secondary)
                        .frame(width: Self.chevronColumn, height: Self.chevronColumn)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? "Collapse \(row.name)" : "Expand \(row.name)")
            default:
                // A file has nothing to disclose, and a folder we could not read or could not find
                // has nothing to disclose *yet* — its trouble is said by the glyph beside it.
                Color.clear
            }
        }
        .frame(width: Self.chevronColumn)
    }

    @ViewBuilder
    private func contextMenu(for row: FileExplorerRow) -> some View {
        if row.kind.isOpenable {
            Button("Open") { perform(.open(row.id)) }
                .disabled(row.load == .missing)
        }
        Button("Reveal in Finder") { perform(.revealInFinder(row.id)) }
        // The divider belongs to the group below it, not to the menu: a file has nothing in that
        // group, and a separator with nothing after it is a menu that looks like it lost an item.
        if row.kind.isExpandable {
            Divider()
            Button("Refresh") { perform(.refresh(row.id)) }
            if row.kind == .root {
                Button("Close Folder") { perform(.closeFolder(row.id)) }
                // Destructive, and named for what it takes away rather than for the row it
                // removes: closing a folder and cutting an agent's access to it are different
                // decisions, and only one of them is reversible by reopening.
                Button("Revoke Access…", role: .destructive) { perform(.revokeFolder(row.id)) }
            }
        }
    }

    // MARK: - What a click means

    private func activate(_ row: FileExplorerRow) {
        for action in Self.activation(for: row) {
            perform(action)
        }
    }

    /// What a plain click on a row means, as a value.
    ///
    /// Lifted out of the view for the same reason ``FileTabDot`` was: a rule that lives inside a
    /// `@ViewBuilder` closure is a rule no test can reach, and this one has four branches that are
    /// each easy to get quietly wrong. A note is a sentence and does nothing. A row whose file has
    /// gone does nothing, because the alternative is an error sheet for a click the user had every
    /// reason to make. A folder toggles. And opening a file **selects it first**, in that order,
    /// so the row is highlighted before the window changes underneath it — the other order shows
    /// the new document with the old row still lit.
    ///
    /// A row we could not read is still live. Permissions get granted and volumes get mounted, and
    /// a retry is the only affordance we have; ``FileExplorerRow/isInteractive`` draws that line
    /// and this defers to it rather than inventing a second one.
    public static func activation(for row: FileExplorerRow) -> [FileExplorerAction] {
        guard row.isInteractive else { return [] }
        if row.kind.isExpandable { return [.toggle(row.id)] }
        if row.kind.isOpenable { return [.select(row.id), .open(row.id)] }
        return []
    }

    // MARK: - Trouble

    /// The glyph replaces the kind's own when something is wrong with the row.
    ///
    /// Replaces rather than joins it: at 11 points there is room for one symbol, and the useful
    /// one is the problem rather than the fact that a folder is a folder.
    private func symbolName(for row: FileExplorerRow) -> String {
        switch row.load {
        case .unreadable: "exclamationmark.triangle"
        case .missing: "questionmark.folder"
        case .idle, .loading: row.kind.symbolName
        }
    }

    private func glyphTint(for row: FileExplorerRow) -> Color {
        switch row.load {
        case .unreadable, .missing: DS.Chrome.secondary
        case .idle, .loading: row.kind.isOpenable ? DS.Chrome.accent : DS.Chrome.secondary
        }
    }

    /// What the pointer says. A healthy row says its own identity — which of the four `data.csv`s
    /// on this machine this one is — and a row in trouble says what the trouble is instead.
    private func helpText(for row: FileExplorerRow) -> String {
        switch row.load {
        case .unreadable: "Not readable."
        case .missing: "This folder is no longer where it was."
        case .idle, .loading: row.id
        }
    }

    // MARK: - Sizes

    // Not spacing, so not on the `DS.Space` scale: each of these is the size of a specific graphic
    // or a measured column, and naming them is what says they were measured rather than nudged.

    /// One level of nesting. Finder's list view and VS Code's explorer both indent by twelve to
    /// thirteen points, which is the narrowest step where the hierarchy is still readable at a
    /// glance — and the rail this sits in is 248 points wide, so a five-deep path has to leave
    /// room for a file name.
    private static let indentPerLevel: CGFloat = 12

    /// The `×` on a root row. Matched to ``FileTabStrip``'s close, because it is the same gesture
    /// on the same kind of thing — put this away — and two sizes for one idea reads as two ideas.
    private static let closeGlyphSize: CGFloat = 9
    private static let closeHitTarget: CGFloat = 16

    /// The disclosure column. Sized for `ProgressView().controlSize(.small)`, which is the widest
    /// of the three things that go here; the chevron and the empty case are held to it.
    private static let chevronColumn: CGFloat = 16

    /// A small chevron reads as a disclosure triangle; a large one reads as a navigation arrow.
    private static let chevronGlyphSize: CGFloat = 9

    /// `.small` is still 16 points tall in a 12-point row. This brings the spinner down to the
    /// chevron's own footprint so a loading folder is exactly as tall as a loaded one.
    private static let spinnerScale: CGFloat = 0.6

    /// Matches ``SidebarRow``'s symbol column exactly, so the file tree and the sheet list below
    /// it in the same sidebar line their names up.
    private static let glyphSize: CGFloat = 11
    private static let glyphColumn: CGFloat = 14

    /// A 16-point square around a 10-point glyph, which is what keeps a small `+` clickable next
    /// to an 11-point section label without making the header taller than the label.
    private static let headerGlyphSize: CGFloat = 10
    private static let headerHitTarget: CGFloat = 16

    private static let fieldGlyphSize: CGFloat = 11

    /// How far down a row goes when we cannot read it or cannot find it.
    ///
    /// Dimmed, not hidden. A granted folder that has been unmounted is a fact the user needs in
    /// order to act on it — removing the row would answer "where did my folder go" by making the
    /// question impossible to ask.
    private static let troubledRowOpacity: CGFloat = 0.45
}
