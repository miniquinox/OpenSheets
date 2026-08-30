import SwiftUI

/// One open file.
///
/// Everything here is a resolved string. The strip has no idea what a `URL` is, what a workspace
/// grant is, or what state the sync machine is in — the app layer answers all three and hands down
/// the answers, the same way it builds `snapshotState` for the snapshot browser. That is what makes
/// this previewable and what keeps `GlassUI` free of a `DocumentCore` import.
public struct FileTabItem: Sendable, Hashable, Identifiable {
    /// The document's identity — `AppModel.documentKey(for:)`, the same string the model layer
    /// uses. Two spellings of one path are one tab because they are one key.
    public var id: String

    /// The file name, extension included. `budget.xlsx`, not `budget`: this app's whole premise is
    /// that the file on disk is the API, and hiding half its name from the person watching it
    /// change would be a strange place to start.
    public var title: String

    /// The parent folder's name, shown only when two open files share a title.
    ///
    /// VS Code's rule, and it is the right one: a disambiguator on every tab is noise, and a
    /// disambiguator on none of them is a window with two identical tabs in it. The app layer
    /// decides when the collision exists; the strip just draws what it is told. Three-way
    /// collisions still get one level — the full path is one hover away.
    public var disambiguator: String?

    /// The whole path, for ``SwiftUI/View/help(_:)``. This is the provenance answer: which of the
    /// four `data.csv`s on this machine am I actually looking at.
    public var fullPath: String

    public var status: Status

    /// One dot per tab, worst news first (plan §1.5). The precedence is resolved by the app layer
    /// before it gets here — a tab has exactly one status, never a set of them, because a tab is
    /// 90 points wide and two dots on it is a decoration rather than a signal.
    public enum Status: Sendable, Hashable {
        /// Synced, saved, nothing to say.
        case none
        /// The document is still opening.
        case loading
        /// Unsaved local edits. Grey, and the same dot the title bar has always shown.
        case unsaved
        /// Changed on disk, or refreshed from disk in the last few seconds. The accent, because
        /// the accent is what "the agent touched this" means everywhere else in the app.
        case agentChanged
        /// Local edits and disk edits disagree.
        case conflict
        /// Missing, locked, unreadable, or the open failed outright.
        case problem
    }

    public init(
        id: String,
        title: String,
        disambiguator: String? = nil,
        fullPath: String,
        status: Status = .none
    ) {
        self.id = id
        self.title = title
        self.disambiguator = disambiguator
        self.fullPath = fullPath
        self.status = status
    }

    /// What VoiceOver reads. The status is spoken, not left to the dot's colour — the dot is 5
    /// points across and colour is the one channel that is not available to everybody.
    public var accessibilityLabel: String {
        var label = title
        if let disambiguator { label += ", in \(disambiguator)" }
        if let spoken = FileTabDot(status).spokenStatus { label += ", \(spoken)" }
        return label
    }
}

public struct FileTabStripState: Sendable, Hashable {
    public var tabs: [FileTabItem]
    public var activeID: String?

    public init(tabs: [FileTabItem], activeID: String? = nil) {
        self.tabs = tabs
        self.activeID = activeID
    }

    public var isEmpty: Bool { tabs.isEmpty }
}

public enum FileTabAction: Sendable, Hashable {
    case select(String)
    case close(String)
    case closeOthers(String)
    case revealInFinder(String)
    case copyPath(String)
    /// The `+` after the last tab. Two verbs rather than one, because a file and a folder do
    /// different things here — a file becomes a tab, a folder joins the tree beside whatever is
    /// already open — and a single "add" the host has to disambiguate is a question asked twice.
    case openFile
    case openFolder
    /// Dragged from one position to another. Indices into ``FileTabStripState/tabs`` as the view
    /// currently shows it — the host owns what that means for its own ordering.
    case reorder(from: Int, to: Int)
}

/// How a status is drawn, as a value.
///
/// Split out of the view for one reason: the precedence in plan §1.5 is a rule the app layer and
/// this strip have to agree on, and a rule buried in a `switch` inside a `@ViewBuilder` is a rule
/// no test can reach. This one is pure, `Hashable`, and asserted directly in `ComponentModelTests`.
enum FileTabDot: Sendable, Hashable {
    /// No dot at all. Not a transparent dot — an absent one, so the title sits where it sits on
    /// every other quiet tab and the row does not shift when a document settles.
    case absent
    case progress
    case unsaved
    case agent
    case conflict
    case problem

    init(_ status: FileTabItem.Status) {
        self = switch status {
        case .none: .absent
        case .loading: .progress
        case .unsaved: .unsaved
        case .agentChanged: .agent
        case .conflict: .conflict
        case .problem: .problem
        }
    }

    /// `nil` for ``absent`` and ``progress``: nothing is drawn for the first, and the second draws
    /// a spinner rather than a dot.
    ///
    /// # Why the active tab is a separate case
    ///
    /// The active tab is a filled accent capsule, and the agent dot is `DS.Chrome.accent` — so on
    /// the active tab it was accent on accent and simply disappeared. That is the one signal this
    /// strip exists to carry (*which file did Claude just touch*), and it went missing on the tab
    /// the user is most likely to be looking at.
    ///
    /// So on the active capsule every dot is drawn in `onAccent`, exactly as the title text beside
    /// it already is. The colour stops encoding *which* status it is there — but the shape is
    /// still "something is up with this file", the tooltip and the VoiceOver label still name it,
    /// and the sync chip a few points to the right carries the detail in full. A dot you can see
    /// that says less beats a correctly-coloured dot you cannot see at all.
    func color(_ context: AppearanceContext, onAccent: Bool) -> Color? {
        if onAccent {
            return self == .absent || self == .progress ? nil : DS.Chrome.onAccent
        }
        return switch self {
        case .absent, .progress: nil
        case .unsaved: DS.Chrome.secondary
        case .agent: DS.Chrome.accent
        case .conflict: DS.Signal.conflictInk(context)
        case .problem: DS.Change.removedInk(context)
        }
    }

    /// The word VoiceOver says, and the `.help` suffix. `nil` when there is nothing to say.
    var spokenStatus: String? {
        switch self {
        case .absent: nil
        case .progress: "opening"
        case .unsaved: "unsaved changes"
        case .agent: "changed on disk"
        case .conflict: "conflict"
        case .problem: "unavailable"
        }
    }
}

/// The file tabs, on the traffic-light line.
///
/// # One lens, N fills
///
/// The same rule as ``SheetTabBar`` and for the same reason: the strip is the glass, the tabs are
/// fills inside it. A row of eight glass capsules is eight lenses in a line, which is both the
/// visual tell of a fake and — at eight open files, each one blurring the backdrop separately —
/// genuinely slow.
///
/// # Why it hugs its content
///
/// This sits in the window's title bar row, inline with the traffic lights, and the empty stretches
/// of that row have to keep dragging the window (see `App/WindowSupport.swift`). A `ScrollView` is
/// greedy horizontally: dropped into that row unchecked it would eat the `Spacer` beside it, and
/// the window would stop being draggable anywhere along the top. So the tab row is measured and the
/// scroller is capped at its content width — the strip is exactly as wide as its tabs until the
/// window is too narrow for them, and only then does it scroll. Everything it does not occupy stays
/// click-through.
///
/// # What it deliberately does not do
///
/// **No drag-to-reorder in v1.** ``SheetTabBar/body`` has the `.draggable`/`.dropDestination` pair
/// and it is the template for when this gets it; the order here is the order files were opened, and
/// adding a reorder gesture to a control that also has a hover-revealed close button is the kind of
/// thing that wants a round of use before it ships. Tab pinning and dragging a tab out into its own
/// window are out of scope for the same reason (plan §5).
public struct FileTabStrip: View {
    private let state: FileTabStripState
    private let context: AppearanceContext
    private let perform: (FileTabAction) -> Void

    @State private var hoveredID: String?
    /// The tab a drag is currently over, for the drop indicator.
    @State private var dropTargetID: String?
    /// Where the dragged tab came from, so the indicator can sit on the correct edge.
    @State private var dragOrigin: Int?
    /// The laid-out width of the tab row, which is what caps the scroller. See the note above.
    @State private var contentWidth: CGFloat?

    public init(
        state: FileTabStripState,
        context: AppearanceContext,
        perform: @escaping (FileTabAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        if state.tabs.isEmpty {
            // Structurally absent, not merely invisible. A transparent strip in the title bar row
            // would still hit-test, and it would swallow exactly the clicks that are supposed to
            // fall through to AppKit and drag the window.
            Color.clear
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            strip
        }
    }

    /// The `+` at the end of the row.
    ///
    /// A `Menu`, not a button: the two things it can add are genuinely different and neither is
    /// the obvious default, so picking one for the user and hiding the other behind a modifier
    /// key would make the second unreachable for anybody who does not know it is there.
    ///
    /// Inside the scroller with the tabs rather than pinned beside it, so it sits immediately
    /// after the last tab instead of at a fixed right edge with a gap in between — and so it
    /// scrolls out of the way when there are more tabs than room, which is when the row has
    /// better uses for the width.
    private var addButton: some View {
        Menu {
            Button("Open File…") { perform(.openFile) }
            Button("Open Folder…") { perform(.openFolder) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Self.addGlyphSize, weight: .semibold))
                .foregroundStyle(DS.Chrome.secondary)
                .frame(width: Self.addHitTarget, height: Self.addHitTarget)
                .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverTitle("Open a file or a folder")
        .accessibilityLabel("Open file or folder")
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.xs) {
                ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                    tabView(tab, at: index)
                }
                addButton
            }
            .padding(.horizontal, DS.Space.hair)
            // Take the ideal width, then report it: this is the pair that makes the strip hug.
            // Without the `fixedSize` the row would stretch to whatever the scroller was given,
            // and the measurement would be of the window rather than of the tabs.
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        // `nil` on the first pass, which lets the content lay out at its ideal size so there is
        // something to measure. It converges in one pass — the tabs' width does not depend on the
        // scroller's.
        .frame(maxWidth: contentWidth)
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.chipY)
        .glassChrome(context: context, radius: DS.Radius.control)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open files")
    }

    // MARK: One tab

    /// Records where a drag started and hands AppKit the payload.
    ///
    /// A method rather than a closure body: `.onDrag(_:preview:)` takes a `ViewBuilder` for the
    /// preview, and a multi-statement closure in the first argument is enough for the compiler to
    /// try applying that builder to the wrong one.
    private func beginDrag(_ tab: FileTabItem, at index: Int) -> NSItemProvider {
        dragOrigin = index
        return NSItemProvider(object: tab.id as NSString)
    }

    /// Which edge of the target tab the drop indicator sits on.
    ///
    /// Trailing when the tab is travelling right and leading when it is travelling left, which is
    /// where ``DocumentCore/TabsModel/move(from:to:)`` actually puts it: removing the dragged tab
    /// first shifts everything to its right down one, so the same index means "after" going right
    /// and "before" going left. The indicator follows the arithmetic rather than the other way
    /// round, because the arithmetic is what puts the tab under the pointer.
    private func dropEdge(for index: Int) -> Alignment {
        guard let origin = dragOrigin else { return .leading }
        return origin < index ? .trailing : .leading
    }

    @ViewBuilder
    private func tabView(_ tab: FileTabItem, at index: Int) -> some View {
        let isActive = tab.id == state.activeID
        // The close button is always on the active tab and appears on hover elsewhere. Always-on
        // would put a row of ✕ across the title bar; hover-only on the active tab would mean the
        // one tab you are most likely to close is the one whose close button you have to go
        // looking for.
        let showsClose = isActive || hoveredID == tab.id

        HStack(spacing: DS.Space.xs) {
            statusIndicator(tab.status, onAccent: isActive)

            Text(tab.title)
                .font(isActive ? DS.Text.controlEmphasis : DS.Text.control)
                .lineLimit(1)
                .truncationMode(.middle)

            if let disambiguator = tab.disambiguator {
                Text(disambiguator)
                    .font(DS.Text.caption)
                    .foregroundStyle(isActive ? DS.Chrome.onAccent.opacity(0.75) : DS.Chrome.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityHidden(true)
            }

            closeButton(tab)
                .opacity(showsClose ? 1 : 0)
                // Reserved whether or not it is drawn, so a tab does not change width under the
                // pointer. A title that shuffles sideways on hover is the fastest way to make a
                // tab strip feel cheap.
                .allowsHitTesting(showsClose)
        }
        .foregroundStyle(isActive ? DS.Chrome.onAccent : DS.Chrome.primary)
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.chipY)
        .background {
            if isActive {
                Capsule(style: .continuous).fill(DS.Chrome.accent)
            } else if hoveredID == tab.id {
                Capsule(style: .continuous).fill(DS.Chrome.separator)
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { perform(.select(tab.id)) }
        .onHover { hoveredID = $0 ? tab.id : (hoveredID == tab.id ? nil : hoveredID) }
        .contextMenu { contextMenu(for: tab) }
        // Reorder by dragging, the way every browser does. The payload is the tab's id — the
        // document key — rather than its index, because an index goes stale the moment a tab
        // opens or closes mid-drag and would move the wrong file.
        // `.onDrag` rather than `.draggable`, for one reason: its closure runs when the drag
        // *starts*, which is the only place the origin index can be recorded. The indicator has to
        // know which way the tab is travelling to sit on the edge it will actually land against,
        // and `.draggable`'s preview builder is not a place to put a side effect.
        .onDrag { beginDrag(tab, at: index) } preview: {
            Text(tab.title)
                .font(DS.Text.control)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first,
                  let from = state.tabs.firstIndex(where: { $0.id == dragged }),
                  from != index
            else { return false }
            perform(.reorder(from: from, to: index))
            dragOrigin = nil
            dropTargetID = nil
            return true
        } isTargeted: { targeted in
            dropTargetID = targeted ? tab.id : (dropTargetID == tab.id ? nil : dropTargetID)
        }
        // A line on the edge the tab will land against, so the drop is predictable before it
        // happens. Leading when dragging left, trailing when dragging right — which is where the
        // tab actually ends up, given how `TabsModel.move` resolves the index.
        .overlay(alignment: dropEdge(for: index)) {
            if dropTargetID == tab.id {
                Capsule(style: .continuous)
                    .fill(DS.Chrome.accent)
                    .frame(width: Self.dropIndicatorWidth)
            }
        }
        .hoverTitle(tab.fullPath)
        .animation(DS.Motion.snappy, value: isActive)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityHint(tab.fullPath)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func statusIndicator(_ status: FileTabItem.Status, onAccent: Bool) -> some View {
        let dot = FileTabDot(status)
        switch dot {
        case .absent:
            EmptyView()
        case .progress:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(Self.miniProgressScale)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .accessibilityHidden(true)
        default:
            Circle()
                .fill(dot.color(context, onAccent: onAccent) ?? Color.clear)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .accessibilityHidden(true)
        }
    }

    private func closeButton(_ tab: FileTabItem) -> some View {
        Button { perform(.close(tab.id)) } label: {
            Image(systemName: "xmark")
                .font(.system(size: Self.closeGlyphSize, weight: .semibold))
                .frame(width: Self.closeHitTarget, height: Self.closeHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTitle("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title)")
    }

    @ViewBuilder
    private func contextMenu(for tab: FileTabItem) -> some View {
        Button("Close") { perform(.close(tab.id)) }
        Button("Close Others") { perform(.closeOthers(tab.id)) }
            .disabled(state.tabs.count < 2)
        Divider()
        Button("Reveal in Finder") { perform(.revealInFinder(tab.id)) }
        Button("Copy Path") { perform(.copyPath(tab.id)) }
    }

    // MARK: Sizes

    // Not spacing, so not on the `DS.Space` scale: each of these is the size of a specific graphic,
    // and naming them is what tells the next person they were measured rather than nudged.

    /// The status dot, matching the sheet tab bar's pending-change dot exactly. Two dots of
    /// different sizes meaning "something changed" in one window is a detail people notice without
    /// being able to say what is wrong.
    private static let dotDiameter: CGFloat = 5

    /// `.mini` is still 12 points across at the top of a 20-point tab. This brings the spinner down
    /// to the dot's own footprint so a loading tab is exactly as wide as a loaded one.
    private static let miniProgressScale: CGFloat = 0.5

    /// A 16-point square around a 9-point glyph — `DS.Space.hitSlop` worth of air on each side,
    /// which is what keeps a small ✕ clickable without enlarging the tab.
    private static let closeHitTarget: CGFloat = 16
    private static let closeGlyphSize: CGFloat = 9

    /// The drop indicator. Thin enough to read as an insertion point rather than as a tab.
    private static let dropIndicatorWidth: CGFloat = 2

    /// The `+`. Matched to the close glyph rather than to the tab text: both are chrome on a tab
    /// row, and a plus that reads as a heading makes the row look like it has two title weights.
    private static let addGlyphSize: CGFloat = 11
    private static let addHitTarget: CGFloat = 22
}
