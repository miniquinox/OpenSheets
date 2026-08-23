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
    public var isWatching: Bool

    public init(
        workspacePath: String,
        isGranted: Bool,
        mcpStatus: MCPStatus,
        feed: [SessionFeedEntry] = [],
        isWatching: Bool = true
    ) {
        self.workspacePath = workspacePath
        self.isGranted = isGranted
        self.mcpStatus = mcpStatus
        self.feed = feed
        self.isWatching = isWatching
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
        size: String,
        modified: String,
        format: String,
        sheetCount: Int,
        isReadOnly: Bool = false,
        containsMacros: Bool = false
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
        self.format = format
        self.sheetCount = sheetCount
        self.isReadOnly = isReadOnly
        self.containsMacros = containsMacros
    }
}

// MARK: - Sidebar

public struct SidebarState: Sendable, Hashable {
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
    case toggleWatching
}

/// Sheets · named ranges · file · **Claude**.
///
/// Chrome glass, edge-anchored, with the grid running under its inner edge via
/// ``SwiftUI/View/gridPlane(_:)`` on the container.
///
/// The Claude panel is at the bottom rather than the top, which is deliberate: it is the section
/// you glance at, not the one you work in. Sheets are what you click.
public struct Sidebar: View {
    private let state: SidebarState
    private let context: AppearanceContext
    private let perform: (SidebarAction) -> Void

    public init(
        state: SidebarState,
        context: AppearanceContext,
        perform: @escaping (SidebarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    sheetsSection
                    namedRangesSection
                    fileSection
                }
                .padding(DS.Space.l)
            }
            .scrollIndicators(.never)
            Divider().overlay(DS.Chrome.separator(context))
            ClaudePanel(state: state.claude, context: context, perform: perform)
        }
        .frame(width: 248)
        .glassChrome(context: context, radius: DS.Radius.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
    }

    private var sheetsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Sheets", trailing: "\(state.sheets.count)")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(state.sheets) { sheet in
                    SidebarRow(
                        title: sheet.name,
                        symbol: sheet.visibility == .visible ? "tablecells" : "eye.slash",
                        badge: sheet.pendingChangeCount > 0 ? "\(sheet.pendingChangeCount)" : nil,
                        accentDot: sheet.colorIndex.map { swatch($0) },
                        isSelected: sheet.id == state.selection,
                        context: context
                    ) { perform(.selectSheet(sheet.id)) }
                }
            }
        }
    }

    @ViewBuilder
    private var namedRangesSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Named ranges", trailing: "\(state.definedNames.count)")
            if state.definedNames.isEmpty {
                Text("This workbook has none.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.definedNames) { item in
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

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("File")
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                DetailRow("Name", state.fileInfo.name)
                DetailRow("Format", state.fileInfo.format)
                DetailRow("Size", state.fileInfo.size, numeric: true)
                DetailRow("Modified", state.fileInfo.modified)
                DetailRow("Sheets", "\(state.fileInfo.sheetCount)", numeric: true)
                if state.fileInfo.isReadOnly {
                    Label("Read-only", systemImage: "lock")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Signal.calmInk(context))
                }
                if state.fileInfo.containsMacros {
                    Label("Contains macros, not executed", systemImage: "curlybraces")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Signal.calmInk(context))
                        .help("Macros are preserved byte-for-byte on save and never run.")
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
            Button { perform(.toggleWatching) } label: {
                Image(systemName: state.isWatching ? "eye" : "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DS.Chrome.secondary)
            }
            .buttonStyle(.plain)
            .help(state.isWatching ? "Pause watching this file" : "Resume watching this file")
            .accessibilityLabel(state.isWatching ? "Pause watching" : "Resume watching")
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
                .help(state.workspacePath)

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
                .help("Lets the MCP server read and write files inside this folder, and nowhere else.")
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
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 1) {
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
                .help("Copy the `claude mcp add` command")
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
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
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
