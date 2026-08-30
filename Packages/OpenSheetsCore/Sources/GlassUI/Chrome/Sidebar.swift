import SheetModel
import SwiftUI

// MARK: - Claude

/// Whether the MCP server is reachable.
///
/// `.notConfigured` is the state that matters most and the one that is easiest to forget: the app
/// is installed, the folder is granted, and the user has simply never run `claude mcp add`. That
/// deserves an instruction, not a red dot — see ``ClaudePanelState/statusDetail``.
public enum MCPStatus: Sendable, Hashable {
    /// Claude Code has the server registered and it answered.
    case connected
    /// Registered, but nothing has called it this session.
    case idle
    /// Never registered.
    case notConfigured
    /// Registered and failing, with the reason.
    case failing(String)

    public var label: String {
        switch self {
        case .connected: "Connected"
        case .idle: "Ready"
        case .notConfigured: "Not set up"
        case .failing: "Not responding"
        }
    }

    public var signal: DS.SignalKind {
        switch self {
        case .connected, .idle: .neutral
        case .notConfigured: .neutral
        case .failing: .failure
        }
    }
}

/// One line in the session feed.
///
/// PLAN.md §1.2 step 7: the sidebar keeps a record of every refresh so you can retrace what the
/// agent did. This is that record — and it is the reason the feature is trustworthy rather than
/// merely convenient. Being able to scroll back through *"14:22 · Q4 · 42 cells"* is what makes
/// handing a spreadsheet to an agent a reversible decision.
public struct SessionFeedEntry: Sendable, Hashable, Identifiable {
    public var id: String
    /// "14:22", already formatted. This package does not own a clock or a locale.
    public var timestamp: String
    /// "Added a Q4 column", or "42 cells across 1 sheet" when there is nothing better to say.
    public var summary: String
    public var sheetName: String?
    public var cellCount: Int
    public var signal: DS.SignalKind

    public init(
        id: String,
        timestamp: String,
        summary: String,
        sheetName: String? = nil,
        cellCount: Int = 0,
        signal: DS.SignalKind = .agent
    ) {
        self.id = id
        self.timestamp = timestamp
        self.summary = summary
        self.sheetName = sheetName
        self.cellCount = cellCount
        self.signal = signal
    }
}

public struct ClaudePanelState: Sendable, Hashable {
    /// The granted folder. Shown in full, truncated in the middle, because the interesting part
    /// of a path is both ends.
    public var workspacePath: String
    /// Whether that folder is an active `workspace_grant` (PLAN.md §7.2).
    public var isGranted: Bool
    public var mcpStatus: MCPStatus
    public var feed: [SessionFeedEntry]
    /// Whether the file watcher is running. Paused is a legitimate state, not an error.

    public init(
        workspacePath: String,
        isGranted: Bool,
        mcpStatus: MCPStatus,
        feed: [SessionFeedEntry] = [],
    ) {
        self.workspacePath = workspacePath
        self.isGranted = isGranted
        self.mcpStatus = mcpStatus
        self.feed = feed
    }

    /// The sentence under the status dot. Every state gets one, and the unhappy ones say what to
    /// do rather than what went wrong.
    public var statusDetail: String {
        switch mcpStatus {
        case .connected: "Claude Code can read and write this workbook."
        case .idle: "Registered. Nothing has called it yet."
        case .notConfigured: "Run `claude mcp add opensheets` in this folder."
        case let .failing(reason): reason
        }
    }
}

// MARK: - File info

public struct FileInfo: Sendable, Hashable {
    public var name: String
    public var path: String

    /// The folder the file lives in, already abbreviated for display (`~/work/budget`).
    ///
    /// Provenance at rest. A tab's tooltip answers "where is this one from" while the pointer is
    /// over the tab; this answers it for the file you are looking at, without a gesture — which is
    /// the question two tabs both reading `data.csv` raise and then leave hanging (plan §1.2
    /// step 4). ``path`` stays the full, unabbreviated spelling for the tooltip, because a
    /// truncated path is a path you cannot paste.
    public var folder: String

    /// "412 KB", already formatted.
    public var size: String
    /// "Today at 14:22", already formatted.
    public var modified: String
    public var format: String
    public var sheetCount: Int
    public var isReadOnly: Bool
    /// PLAN.md §7.3 — we pass `vbaProject.bin` through on save and say so. We never execute it.
    public var containsMacros: Bool

    public init(
        name: String,
        path: String,
        folder: String = "",
        size: String,
        modified: String,
        format: String,
        sheetCount: Int,
        isReadOnly: Bool = false,
        containsMacros: Bool = false
    ) {
        self.name = name
        self.path = path
        self.folder = folder
        self.size = size
        self.modified = modified
        self.format = format
        self.sheetCount = sheetCount
        self.isReadOnly = isReadOnly
        self.containsMacros = containsMacros
    }
}

// MARK: - Sidebar

/// Everything in the sidebar that needs an open workbook to mean anything.
///
/// Bundled and made optional together because they arrive and leave together: a window opened as
/// a *folder* has no sheets, no defined names, no file to describe and no workspace root for the
/// Claude panel to name. Four independent optionals would let a caller express three states that
/// cannot happen, and the sidebar would have to decide what half a document looks like.
public struct SidebarDocument: Sendable, Hashable {
    public var sheets: [SheetTabItem]
    public var selection: SheetID?
    public var definedNames: [DefinedNameItem]
    public var fileInfo: FileInfo
    public var claude: ClaudePanelState

    public init(
        sheets: [SheetTabItem],
        selection: SheetID?,
        definedNames: [DefinedNameItem],
        fileInfo: FileInfo,
        claude: ClaudePanelState
    ) {
        self.sheets = sheets
        self.selection = selection
        self.definedNames = definedNames
        self.fileInfo = fileInfo
        self.claude = claude
    }
}

public struct SidebarState: Sendable, Hashable {
    /// The open workbook's half of the column, or `nil` when the window has none yet — a folder
    /// was opened and no file has been picked. Same reasoning as ``files``: absent means absent,
    /// not "present and empty", because an empty Sheets header in a 248pt column is furniture
    /// describing something that does not exist.
    public var document: SidebarDocument?

    /// The granted folders, as a tree — or `nil` for *draw no such section at all*.
    ///
    /// `nil` rather than an empty ``FileExplorerState`` on purpose, and the distinction is the
    /// whole flag-off contract: an empty state still draws a header, a search field and a
    /// sentence about having nothing, which is furniture in a 248pt column for a feature the user
    /// has switched off or never used. Absent means absent, and the sidebar is byte-for-byte what
    /// it was before the explorer existed.
    ///
    /// Defaulted so that every existing construction site — and the gallery's fixture — keeps
    /// compiling and keeps meaning what it meant.
    public var files: FileExplorerState?

    /// The document window's sidebar. Unchanged in shape from before there was a folder-only
    /// case, so every existing call site and the gallery's fixture keep meaning what they meant.
    public init(
        sheets: [SheetTabItem],
        selection: SheetID?,
        definedNames: [DefinedNameItem],
        fileInfo: FileInfo,
        claude: ClaudePanelState,
        files: FileExplorerState? = nil
    ) {
        document = SidebarDocument(
            sheets: sheets,
            selection: selection,
            definedNames: definedNames,
            fileInfo: fileInfo,
            claude: claude
        )
        self.files = files
    }

    /// A window that has a folder open and no workbook in it. Only the file tree is drawn.
    public init(files: FileExplorerState?) {
        document = nil
        self.files = files
    }
}

public enum SidebarAction: Sendable, Hashable {
    case selectSheet(SheetID)
    case selectDefinedName(String)
    case revealInFinder
    /// PLAN.md §12: opens Terminal or iTerm2 at the workspace root with `claude` typed but **not
    /// executed**. The user presses Return. Running a command in someone's shell without them
    /// asking is not a feature.
    case openTerminal
    case grantWorkspace
    case revokeWorkspace
    case copyMCPSetupCommand
    case showFeedEntry(String)
    /// Forwarded verbatim from the files section. Wrapped rather than flattened into eight more
    /// cases so that the explorer's vocabulary stays the explorer's: the sidebar is a courier
    /// here, and a courier that re-spells the message is one that can get it wrong.
    case explorer(FileExplorerAction)
}

/// Files · sheets · named ranges · file · **Claude**.
///
/// # Flush, not floating
///
/// This is a native sidebar: it runs the full height of the window, has no corner radius of its
/// own, and meets the grid at a hairline. It is *not* a card with a margin around it.
///
/// The choice was between the two idioms and it is not a matter of taste. A floating panel only
/// reads as floating when the content continues *underneath* it — that is what the shadow and the
/// inset are evidence of. Here the grid is a sibling column that stops at the sidebar's inner
/// edge, so an inset panel would be a card floating over nothing, with a strip of desktop showing
/// down its outside. That is the state the window was already in: card corners, no margin to put
/// them in, and a 1pt separator butted against them.
///
/// The flush form also gives the grid back the ~40pt that margins would have cost, which in a
/// spreadsheet is most of another column.
///
/// # The material
///
/// ``ChromeVibrancy/sidebar`` — a real `NSVisualEffectView`, not Liquid Glass. The distinction and
/// the reason for it are in ``ChromeVibrancy``; the short version is that a lens refracts *window
/// content* and there is none behind this column, so glass here degrades to a clear hole onto the
/// desktop. The material gives the diffuse cast of the wallpaper that a Mac sidebar has.
///
/// # `topInset`
///
/// The anchored chrome band spans the full window width and floats *over* this column, so the
/// material runs up behind it while the content starts below it. The caller measures the band and
/// passes its height rather than anybody hardcoding one — see ``DS/Metrics/titleBarHeight`` for
/// why a guessed number here would drift.
///
/// The Claude panel is at the bottom rather than the top, which is deliberate: it is the section
/// you glance at, not the one you work in. Sheets are what you click.
///
/// # Why `Files` is first
///
/// It is the only section that can take you somewhere else. Everything below it is about the
/// workbook you already have open, so a tree that answers *"what else is in this folder"* belongs
/// above them for the same reason a file list is at the top of every editor's sidebar — you
/// navigate before you work, not after. It is also the only section that is ever absent, and a
/// section that appears and disappears in the middle of a column reshuffles everything under it.
public struct Sidebar: View {
    private let state: SidebarState
    private let context: AppearanceContext
    private let topInset: CGFloat
    private let perform: (SidebarAction) -> Void

    public init(
        state: SidebarState,
        context: AppearanceContext,
        topInset: CGFloat = 0,
        perform: @escaping (SidebarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.topInset = topInset
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    filesSection
                    // The workbook's half, drawn only when there is one. A window opened as a
                    // folder shows the tree and stops — three headers describing a file nobody
                    // has picked yet would be the column explaining an absence back to the user.
                    if let document = state.document {
                        sheetsSection(document)
                        namedRangesSection(document)
                        fileSection(document)
                    }
                }
                // The same inset on all four sides. The top-only padding this replaced is what
                // made the column look like it had been dropped in rather than laid out.
                .padding(DS.Space.l)
            }
            .scrollIndicators(.never)
            .safeAreaPadding(.top, topInset)
            // The divider belongs to the panel, not to the column: with no panel it would be a
            // line ruled under the last thing in a scroll view, which reads as a cut-off list.
            if let document = state.document {
                Divider().overlay(DS.Chrome.separator(context))
                ClaudePanel(state: document.claude, context: context, perform: perform)
            }
        }
        .frame(width: DS.Metrics.sidebarWidth)
        .vibrantChrome(.sidebar, context: context, separator: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    /// The granted folders, capped so a deep tree cannot swallow the column.
    ///
    /// Headed `Files` rather than `Folders`: in the launcher the same tree *is* the list of
    /// folders you have granted, but here it is one more thing this document window can show you,
    /// and the thing you come to it for is a file (plan §4.2).
    ///
    /// No surface of its own, and none added here. ``FileExplorer`` deliberately draws no glass
    /// and no material so it can be dropped into somebody else's chrome; wrapping it in one would
    /// put a lens inside a material and give this component six golden diffs it did not plan for.
    @ViewBuilder
    private var filesSection: some View {
        if let files = state.files {
            FileExplorer(state: files, context: context, title: "Files") { action in
                perform(.explorer(action))
            }
            .frame(maxHeight: Self.filesSectionMaxHeight)
        }
    }

    private func sheetsSection(_ document: SidebarDocument) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Sheets", trailing: "\(document.sheets.count)")
            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                ForEach(document.sheets) { sheet in
                    SidebarRow(
                        title: sheet.name,
                        symbol: sheet.visibility == .visible ? "tablecells" : "eye.slash",
                        badge: sheet.pendingChangeCount > 0 ? "\(sheet.pendingChangeCount)" : nil,
                        accentDot: sheet.colorIndex.map { swatch($0) },
                        isSelected: sheet.id == document.selection,
                        context: context
                    ) { perform(.selectSheet(sheet.id)) }
                }
            }
        }
    }

    @ViewBuilder
    private func namedRangesSection(_ document: SidebarDocument) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Named ranges", trailing: "\(document.definedNames.count)")
            if document.definedNames.isEmpty {
                Text("This workbook has none.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.tertiary)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                    ForEach(document.definedNames) { item in
                        SidebarRow(
                            title: item.name,
                            subtitle: item.rangeLabel,
                            symbol: "at",
                            isSelected: false,
                            context: context
                        ) { perform(.selectDefinedName(item.name)) }
                    }
                }
            }
        }
    }

    private func fileSection(_ document: SidebarDocument) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("File")
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DetailRow("Name", document.fileInfo.name)
                // Where the file is, not just what it is called. The row truncates in the middle
                // (``DetailRow``), which keeps both the interesting ends — the volume and the
                // folder — while the full path stays one hover away.
                if !document.fileInfo.folder.isEmpty {
                    DetailRow("Where", document.fileInfo.folder)
                        .hoverTitle(document.fileInfo.path)
                }
                DetailRow("Format", document.fileInfo.format)
                DetailRow("Size", document.fileInfo.size, numeric: true)
                DetailRow("Modified", document.fileInfo.modified)
                DetailRow("Sheets", "\(document.fileInfo.sheetCount)", numeric: true)
                if document.fileInfo.isReadOnly {
                    Label("Read-only", systemImage: "lock")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Signal.calmInk(context))
                }
                if document.fileInfo.containsMacros {
                    Label("Contains macros, not executed", systemImage: "curlybraces")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Signal.calmInk(context))
                        .hoverTitle("Macros are preserved byte-for-byte on save and never run.")
                }
            }
            Button("Show in Finder") { perform(.revealInFinder) }
                .buttonStyle(.plain)
                .font(DS.Text.control)
                .foregroundStyle(DS.Chrome.accent)
        }
    }

    private func swatch(_ index: Int) -> Color {
        guard index < Palette.tabSwatches.count else { return DS.Chrome.secondary }
        let entry = Palette.tabSwatches[index]
        return context.pick(light: entry.light, dark: entry.dark).color
    }

    // MARK: Sizes

    /// How tall the files section may grow before it scrolls inside itself.
    ///
    /// Load-bearing, not a nicety. ``FileExplorer`` imposes no height of its own — height belongs
    /// to the host, by its own design — so without a cap an expanded `~/Documents` would hand this
    /// column several thousand rows and push `Sheets`, `Named ranges` and the whole file section
    /// below the fold of a 248pt sidebar. The one thing a sidebar must never do is hide the
    /// document it belongs to.
    ///
    /// Roughly nine rows plus the header and the search field: enough that a folder reads as a
    /// list rather than as a peephole, and small enough that `Sheets` is still on screen without
    /// scrolling. ``ChangeTrackingPanel``'s `listMaxHeight` is the precedent for spending a named
    /// constant rather than a token on a measurement like this.
    private static let filesSectionMaxHeight: CGFloat = 300
}

/// Workspace · MCP · terminal · what the agent did.
public struct ClaudePanel: View {
    private let state: ClaudePanelState
    private let context: AppearanceContext
    private let perform: (SidebarAction) -> Void

    public init(
        state: ClaudePanelState,
        context: AppearanceContext,
        perform: @escaping (SidebarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            workspaceRow
            statusRow
            actions
            if !state.feed.isEmpty { feedSection }
        }
        .padding(DS.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude")
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Chrome.accent)
            Text("Claude").dsSectionLabel()
            Spacer(minLength: 0)
        }
    }

    private var workspaceRow: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(state.workspacePath)
                .font(DS.Text.path)
                .foregroundStyle(DS.Chrome.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .hoverTitle(state.workspacePath)

            if state.isGranted {
                Label("Granted to Claude", systemImage: "checkmark.shield")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.connected(context))
            } else {
                Button {
                    perform(.grantWorkspace)
                } label: {
                    Label("Grant this folder", systemImage: "shield")
                        .font(DS.Text.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Chrome.accent)
                .hoverTitle("Lets the MCP server read and write files inside this folder, and nowhere else.")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Workspace \(state.workspacePath), \(state.isGranted ? "granted" : "not granted")"
        )
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            AgentDot(
                color: dotColor,
                diameter: 6,
                isActive: state.mcpStatus == .connected,
                reduceMotion: context.reduceMotion
            )
            .padding(.top, DS.Space.xs)

            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                Text(state.mcpStatus.label)
                    .font(DS.Text.controlEmphasis)
                    .foregroundStyle(DS.Chrome.primary)
                Text(state.statusDetail)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("MCP \(state.mcpStatus.label). \(state.statusDetail)")
    }

    private var dotColor: Color {
        switch state.mcpStatus {
        case .connected: DS.Signal.connected(context)
        case .idle: DS.Signal.calmInk(context)
        case .notConfigured: DS.Signal.calmInk(context)
        case .failing: DS.Signal.errorInk(context)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            Button("Open terminal here") { perform(.openTerminal) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if case .notConfigured = state.mcpStatus {
                Button {
                    perform(.copyMCPSetupCommand)
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .hoverTitle("Copy the `claude mcp add` command")
                .accessibilityLabel("Copy setup command")
            }
        }
        .font(DS.Text.control)
    }

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SectionHeader("This session", trailing: "\(state.feed.count)")
            ForEach(state.feed) { entry in
                Button { perform(.showFeedEntry(entry.id)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                        Text(entry.timestamp)
                            .dsNumeric(DS.Text.numericCaption)
                            .foregroundStyle(DS.Chrome.tertiary)
                            .frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.summary)
                                .font(DS.Text.caption)
                                .foregroundStyle(DS.Chrome.primary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let sheetName = entry.sheetName {
                                Text("\(sheetName) · \(entry.cellCount.formatted()) cells")
                                    .dsNumeric(DS.Text.numericCaption)
                                    .foregroundStyle(DS.Chrome.tertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.timestamp), \(entry.summary)")
            }
        }
    }
}

/// A selectable row in the sidebar.
public struct SidebarRow: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String
    private let badge: String?
    private let accentDot: Color?
    private let isSelected: Bool
    private let context: AppearanceContext
    private let action: () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        badge: String? = nil,
        accentDot: Color? = nil,
        isSelected: Bool,
        context: AppearanceContext,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.badge = badge
        self.accentDot = accentDot
        self.isSelected = isSelected
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? DS.Chrome.primary : DS.Chrome.secondary)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(isSelected ? DS.Text.controlEmphasis : DS.Text.control)
                        .foregroundStyle(DS.Chrome.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(DS.Text.mono)
                            .foregroundStyle(DS.Chrome.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DS.Space.xs)

                if let accentDot {
                    Circle().fill(accentDot).frame(width: 6, height: 6)
                }
                if let badge {
                    Text(badge)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.onAccent)
                        .padding(.horizontal, DS.Space.badgeX)
                        .padding(.vertical, DS.Space.rowGap)
                        .background(Capsule(style: .continuous).fill(DS.Chrome.accent))
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs + 1)
            .background {
                if isSelected {
                    DS.Radius.shape(DS.Radius.chip).fill(DS.Chrome.selectedRow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
