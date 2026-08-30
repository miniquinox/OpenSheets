import SheetModel
import SwiftUI

/// Every component in the design system, over a real grid, in every appearance.
///
/// This is the gallery the brief asks for, and it is also how the design was actually made. Two
/// things it does that a page of `#Preview`s cannot:
///
/// - **It puts a grid under the glass.** The `Backdrop` control forces chrome over a *white* grid
///   and over a *dark* grid independently of the colour scheme, which is the only way to check
///   PLAN.md §3.5's requirement that chrome text stays legible over both. A dark toolbar over a
///   white spreadsheet is a real combination — it is what a dark-mode user sees when they open a
///   workbook whose cells are white — and it is where a lazy palette falls apart.
/// - **It follows the live accessibility settings.** ``AccessibilityAppearance`` is wired in, so
///   toggling System Settings ▸ Accessibility ▸ Reduce transparency updates this window without a
///   relaunch. The manual toggles are overrides on top of that, for checking a state you do not
///   currently have switched on.
///
/// It has no dependency on any other Wave 1 target: the grid underneath is ``MockGrid``, and every
/// value comes from ``Mock``.
public struct GlassUIGallery: View {
    /// One entry in the gallery's rail.
    public enum Item: String, Sendable, Hashable, CaseIterable, Identifiable {
        case document
        case syncSurface
        case refreshPill
        case diffPanel
        case conflictBanner
        case toolbar
        case formulaBar
        case sheetTabBar
        case sidebar
        case fileExplorer
        case inspector
        case selectionStats
        case commandPalette
        case snapshotBrowser
        case launcher
        case syncChips
        case emptyStates
        case tokens

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .document: "Document window"
            case .syncSurface: "Pill → panel morph"
            case .refreshPill: "Refresh pill"
            case .diffPanel: "Diff panel"
            case .conflictBanner: "Conflict banner"
            case .toolbar: "Toolbar"
            case .formulaBar: "Formula bar"
            case .sheetTabBar: "Sheet tabs"
            case .sidebar: "Sidebar"
            case .fileExplorer: "File explorer"
            case .inspector: "Inspector"
            case .selectionStats: "Selection stats"
            case .commandPalette: "Command palette"
            case .snapshotBrowser: "Snapshot browser"
            case .launcher: "Launcher"
            case .syncChips: "Sync state chips"
            case .emptyStates: "Empty states"
            case .tokens: "Tokens"
            }
        }

        public var symbol: String {
            switch self {
            case .document: "macwindow"
            case .syncSurface: "arrow.up.left.and.arrow.down.right"
            case .refreshPill: "capsule"
            case .diffPanel: "list.bullet.rectangle"
            case .conflictBanner: "exclamationmark.triangle"
            case .toolbar: "slider.horizontal.3"
            case .formulaBar: "function"
            case .sheetTabBar: "rectangle.split.3x1"
            case .sidebar: "sidebar.left"
            case .fileExplorer: "folder"
            case .inspector: "paintbrush"
            case .selectionStats: "sum"
            case .commandPalette: "command"
            case .snapshotBrowser: "clock.arrow.circlepath"
            case .launcher: "square.grid.2x2"
            case .syncChips: "dot.radiowaves.up.forward"
            case .emptyStates: "questionmark.folder"
            case .tokens: "paintpalette"
            }
        }
    }

    /// Which grid sits under the chrome. Independent of the colour scheme on purpose — see the
    /// type's doc comment.
    public enum Backdrop: String, Sendable, Hashable, CaseIterable, Identifiable {
        case matchScheme
        case whiteGrid
        case darkGrid

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .matchScheme: "Match scheme"
            case .whiteGrid: "White grid"
            case .darkGrid: "Dark grid"
            }
        }
    }

    @State private var item: Item
    @State private var scheme: GlassColorScheme
    @State private var backdrop: Backdrop
    @State private var overrideReduceTransparency: Bool
    @State private var overrideIncreaseContrast: Bool
    @State private var overrideReduceMotion: Bool
    @State private var syncPhase: SyncSurface.Phase
    @State private var statsVisible = SelectionStat.defaultVisible
    @State private var tabSelection: SheetID = 2

    /// Hides the rail and the control bar, leaving only the stage.
    ///
    /// Two uses. The screenshots in `docs/design/` are taken this way, so the picture is the
    /// component rather than the component inside a tool. And A8 can drop a single component into
    /// a debug window without the browser around it.
    private let showsChrome: Bool

    @State private var appearance = AccessibilityAppearance()

    public init(
        item: Item = .document,
        scheme: GlassColorScheme = .dark,
        backdrop: Backdrop = .matchScheme,
        reduceTransparency: Bool = false,
        increaseContrast: Bool = false,
        reduceMotion: Bool = false,
        syncPhase: SyncSurface.Phase = .pill,
        showsChrome: Bool = true
    ) {
        _item = State(initialValue: item)
        _scheme = State(initialValue: scheme)
        _backdrop = State(initialValue: backdrop)
        _overrideReduceTransparency = State(initialValue: reduceTransparency)
        _overrideIncreaseContrast = State(initialValue: increaseContrast)
        _overrideReduceMotion = State(initialValue: reduceMotion)
        _syncPhase = State(initialValue: syncPhase)
        self.showsChrome = showsChrome
    }

    /// The context every component in the gallery is rendered with: the live system settings,
    /// with the gallery's own toggles OR-ed on top.
    private var context: AppearanceContext {
        var resolved = appearance.context(for: scheme.colorScheme)
        resolved.reduceTransparency = resolved.reduceTransparency || overrideReduceTransparency
        resolved.increaseContrast = resolved.increaseContrast || overrideIncreaseContrast
        resolved.reduceMotion = resolved.reduceMotion || overrideReduceMotion
        return resolved
    }

    /// The grid drawn behind everything. When the backdrop is forced, only the *grid's* scheme
    /// flips; the chrome keeps the gallery's scheme, which is exactly the mismatch we want to see.
    private var backdropTheme: GridTheme {
        var gridContext = context
        switch backdrop {
        case .matchScheme: break
        case .whiteGrid: gridContext.colorScheme = .light
        case .darkGrid: gridContext.colorScheme = .dark
        }
        return GridTheme.resolved(gridContext)
    }

    public var body: some View {
        Group {
            if showsChrome {
                HStack(spacing: 0) {
                    rail
                    Divider().overlay(DS.Chrome.separator(context))
                    VStack(spacing: 0) {
                        controls
                        Divider().overlay(DS.Chrome.separator(context))
                        stage
                    }
                }
                .frame(minWidth: 1080, minHeight: 720)
            } else {
                stage
            }
        }
        .glassAppearance(context)
    }

    // MARK: Rail

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                ForEach(Item.allCases) { entry in
                    SidebarRow(
                        title: entry.title,
                        symbol: entry.symbol,
                        isSelected: entry == item,
                        context: context
                    ) { item = entry }
                }
            }
            .padding(DS.Space.s)
        }
        .frame(width: 208)
        .background(DS.Surface.chrome(context))
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: DS.Space.l) {
            Picker("", selection: $scheme) {
                Text("Light").tag(GlassColorScheme.light)
                Text("Dark").tag(GlassColorScheme.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)

            Picker("", selection: $backdrop) {
                ForEach(Backdrop.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 280)

            Toggle("Reduce transparency", isOn: $overrideReduceTransparency)
            Toggle("Increase contrast", isOn: $overrideIncreaseContrast)
            Toggle("Reduce motion", isOn: $overrideReduceMotion)

            Spacer(minLength: 0)

            systemStatus
        }
        .toggleStyle(.checkbox)
        .font(DS.Text.control)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(DS.Surface.chrome(context))
    }

    /// Proof that the live observer works: these move when System Settings moves, with the window
    /// open. If they do not, ``AccessibilityAppearance`` is broken and no amount of screenshotting
    /// will show it.
    private var systemStatus: some View {
        HStack(spacing: DS.Space.s) {
            Text("System:")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
            flag("RT", appearance.reduceTransparency)
            flag("IC", appearance.increaseContrast)
            flag("RM", appearance.reduceMotion)
            flag("DWC", appearance.differentiateWithoutColor)
            Text(appearance.accent.hexString)
                .dsNumeric(DS.Text.numericCaption)
                .foregroundStyle(DS.Chrome.tertiary)
        }
        .hoverTitle("Live from NSWorkspace. Toggle System Settings ▸ Accessibility ▸ Display to watch.")
    }

    private func flag(_ label: String, _ isOn: Bool) -> some View {
        Text(label)
            .font(DS.Text.caption)
            .foregroundStyle(isOn ? DS.Chrome.onAccent : DS.Chrome.tertiary)
            .padding(.horizontal, DS.Space.badgeX)
            .padding(.vertical, DS.Space.rowGap)
            .background {
                Capsule(style: .continuous)
                    .fill(isOn ? DS.Chrome.accent : DS.Chrome.separator)
            }
    }

    // MARK: Stage

    /// The stage draws the grid; the component floats on it.
    ///
    /// Except for the document scene, which is a whole window and brings its own plane. Drawing
    /// the stage's grid behind it too gives you two spreadsheets at two offsets showing through
    /// each other, which is exactly as confusing as it sounds and is the first thing the very
    /// first screenshot showed.
    private var stage: some View {
        ZStack {
            if item != .document {
                MockGrid(theme: backdropTheme)
                    .gridPlane(context)
                content.padding(DS.Space.xxl)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .document:
            DocumentScene(context: context, backdropTheme: backdropTheme)
        case .syncSurface:
            morphDemo
        case .refreshPill:
            GlassCluster {
                VStack(spacing: DS.Space.l) {
                    RefreshPill(notice: Mock.notice, context: context) { _ in }
                    RefreshPill(notice: Mock.conflictNotice, context: context) { _ in }
                    RefreshPill(notice: Mock.failureNotice, context: context) { _ in }
                }
            }
        case .diffPanel:
            DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
        case .conflictBanner:
            ConflictBanner(model: Mock.conflict, context: context) { _ in }
                .frame(maxWidth: 640)
        case .toolbar:
            ToolbarSurface(state: Mock.toolbar, context: context) { _ in }
        case .formulaBar:
            GlassCluster {
                VStack(spacing: DS.Space.l) {
                    FormulaBar(state: Mock.formulaBar, context: context) { _ in }
                    // A literal cell, which is what the bar showed nothing for until `text`
                    // stopped meaning "formula source".
                    FormulaBar(state: Mock.formulaBarLiteral, context: context) { _ in }
                    FormulaBar(state: Mock.formulaBarSpilled, context: context) { _ in }
                    FormulaBar(state: Mock.formulaBarWithError, context: context) { _ in }
                }
            }
            .frame(maxWidth: 720)
        case .sheetTabBar:
            SheetTabBar(
                state: SheetTabBarState(tabs: Mock.tabs, selection: tabSelection),
                context: context
            ) { action in
                if case let .select(id) = action { tabSelection = id }
            }
            .frame(maxWidth: 620)
        case .sidebar:
            HStack {
                Sidebar(state: Mock.sidebar, context: context) { _ in }
                Spacer(minLength: 0)
            }
        case .fileExplorer:
            fileExplorerGallery
        case .inspector:
            HStack {
                Spacer(minLength: 0)
                Inspector(state: Mock.inspector, context: context) { _ in }
            }
        case .selectionStats:
            SelectionStatsPill(
                stats: SelectionStats(
                    rangeLabel: Mock.selectionStats.rangeLabel,
                    values: Mock.selectionStats.values,
                    visible: statsVisible
                ),
                context: context
            ) { action in
                if case .cycle = action { statsVisible = SelectionStats.cycled(statsVisible) }
            }
        case .commandPalette:
            CommandPalette(state: Mock.commandPalette, context: context) { _ in }
        case .snapshotBrowser:
            SnapshotBrowser(state: Mock.snapshots, context: context) { _ in }
        case .launcher:
            LauncherWindow(state: Mock.launcher, context: context) { _ in }
        case .syncChips:
            chipGallery
        case .emptyStates:
            emptyStateGallery
        case .tokens:
            TokenSheet(context: context)
        }
    }

    /// The signature moment, with a switch on it.
    private var morphDemo: some View {
        VStack(spacing: DS.Space.xl) {
            SyncSurface(
                phase: syncPhase,
                changeSet: Mock.changeSet,
                context: context
            ) { action in
                withAnimation(DS.Motion.morph(context)) {
                    switch action {
                    case .expand: syncPhase = .panel
                    case .collapse, .dismiss: syncPhase = .pill
                    default: break
                    }
                }
            }

            Button(syncPhase == .pill ? "Expand" : "Collapse") {
                withAnimation(DS.Motion.morph(context)) {
                    syncPhase = syncPhase == .pill ? .panel : .pill
                }
            }
            .buttonStyle(.bordered)
            .font(DS.Text.control)
        }
    }

    /// The explorer brings no surface of its own — it is content, and in the app it is hosted
    /// inside the launcher's card or the sidebar's vibrant chrome. So the gallery has to supply the
    /// host, or this page would be a review of a file list floating directly on a spreadsheet,
    /// which is a picture of the bug rather than of the component.
    private var fileExplorerGallery: some View {
        FileExplorer(state: Mock.fileExplorer, context: context) { _ in }
            .frame(width: DS.Metrics.sidebarWidth, height: 420)
            .padding(.vertical, DS.Space.s)
            .glassCard(context: context, radius: DS.Radius.panel)
    }

    private var chipGallery: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(Array(Mock.syncStates.enumerated()), id: \.offset) { _, state in
                SyncStateChip(state: state, context: context) {}
            }
        }
        .padding(DS.Space.l)
        .glassCard(context: context, radius: DS.Radius.panel)
    }

    /// All seven states in one column rather than behind tabs.
    ///
    /// The point of reviewing empty states together is to hear whether they sound like one voice.
    /// A tab bar hides six of them behind a click and you end up writing seven different apps.
    private var emptyStateGallery: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                ForEach(Array(EmptyStateModel.all.enumerated()), id: \.offset) { _, model in
                    EmptyStateView(model: model, context: context) { _ in }
                        .frame(height: 210)
                }
            }
            .padding(.vertical, DS.Space.l)
        }
        .scrollIndicators(.never)
        .frame(maxWidth: 640)
    }
}

/// The whole window, assembled. The screenshot that answers "does this look like a product".
public struct DocumentScene: View {
    // glass-lint: separated — the stats pill (bottom-left) and the sync surface (bottom-right)
    // sit at opposite corners and must never merge into one lens; they are different kinds of
    // statement. The chrome is edge-anchored and equally far apart.
    private let context: AppearanceContext
    private let backdropTheme: GridTheme

    /// Room for the pill→panel morph to grow downward into. A measurement of this demo rig, not a
    /// design token — see the use site.
    private static let morphDemoClearance: CGFloat = 58

    @State private var phase: SyncSurface.Phase = .pill

    public init(context: AppearanceContext, backdropTheme: GridTheme) {
        self.context = context
        self.backdropTheme = backdropTheme
    }

    public var body: some View {
        ZStack {
            // The one opaque plane. Everything below floats on it, and it bleeds under all of
            // them via .backgroundExtensionEffect().
            MockGrid(theme: backdropTheme)
                .gridPlane(context)

            HStack(alignment: .top, spacing: 0) {
                Sidebar(state: Mock.sidebar, context: context) { _ in }
                    .padding(.leading, DS.Space.m)
                    .padding(.top, titlebarInset)
                    .padding(.bottom, DS.Space.m)

                // The right-hand column owns both the chrome and the floating layer, so a pill in
                // the bottom-left corner lands next to the grid rather than on top of the sidebar.
                ZStack {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        titlebar
                        ToolbarSurface(state: Mock.toolbar, context: context) { _ in }
                        FormulaBar(state: Mock.formulaBar, context: context) { _ in }
                        Spacer(minLength: 0)
                        HStack {
                            SheetTabBar(state: Mock.tabBar, context: context) { _ in }
                            Spacer(minLength: 0)
                        }
                    }

                    // The floating layer. Two surfaces, deliberately at opposite corners — see
                    // the annotation at the top of this type.
                    VStack {
                        Spacer(minLength: 0)
                        HStack(alignment: .bottom) {
                            SelectionStatsPill(stats: Mock.selectionStats, context: context) { _ in }
                            Spacer(minLength: DS.Space.xxl)
                            SyncSurface(
                                phase: phase,
                                changeSet: Mock.changeSet,
                                context: context
                            ) { action in
                                withAnimation(DS.Motion.morph(context)) {
                                    switch action {
                                    case .expand: phase = .panel
                                    case .collapse, .dismiss: phase = .pill
                                    default: break
                                    }
                                }
                            }
                        }
                        // Clearance for the morph demo's expanded panel, which grows downward
                        // out of the pill and would otherwise be clipped by the scroll view.
                        // A demo-rig measurement, not a design token.
                        .padding(.bottom, Self.morphDemoClearance)
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.m)
            }
        }
    }

    /// Room for the window's own traffic lights. The titlebar is transparent and full-size, so
    /// content that ignores this slides under the close button — which looks like a bug and is one.
    private var titlebarInset: CGFloat { 30 }

    /// The live sync chip, where a unified titlebar would put it.
    ///
    /// The document name is *not* mocked here. The real window draws it, and a floating label with
    /// no surface under it sitting on the grid is the one thing this design system is against —
    /// the first pass had one, and it read as a bug.
    private var titlebar: some View {
        HStack(spacing: DS.Space.s) {
            Spacer(minLength: DS.Space.l)
            SyncStateChip(state: .stale(cellCount: 42), context: context) {}
        }
        .frame(height: titlebarInset)
        .padding(.horizontal, DS.Space.xs)
    }
}

/// The palette and the metrics, as a page. Useful for reviewing tokens in situ rather than in a
/// source file, and it is what `docs/design/tokens.png` is a picture of.
public struct TokenSheet: View {
    private let context: AppearanceContext

    public init(context: AppearanceContext) {
        self.context = context
    }

    private var theme: GridTheme { GridTheme.resolved(context) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                group("Grid plane", [
                    ("canvas", theme.canvas),
                    ("gridline", theme.gridline),
                    ("gridlineMajor", theme.gridlineMajor),
                    ("headerBackground", theme.headerBackground),
                    ("headerActiveBackground", theme.headerActiveBackground),
                ])
                group("Grid ink", [
                    ("cellInk", theme.cellInk),
                    ("cellInkSecondary", theme.cellInkSecondary),
                    ("cellInkFormula", theme.cellInkFormula),
                    ("cellInkError", theme.cellInkError),
                    ("cellInkStale", theme.cellInkStale),
                    ("headerInk", theme.headerInk),
                ])
                group("Selection and the agent", [
                    ("selectionStroke", theme.selectionStroke),
                    ("selectionFill", theme.selectionFill),
                    ("changeFlashFill", theme.changeFlashFill),
                    ("changeMarker", theme.changeMarker),
                ])
                metrics
            }
            .padding(DS.Space.xl)
        }
        .frame(maxWidth: 760)
        .glassCard(context: context)
    }

    private func group(_ title: String, _ colors: [(String, RGBA)]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title)
            ForEach(colors, id: \.0) { name, color in
                HStack(spacing: DS.Space.m) {
                    DS.Radius.shape(6)
                        .fill(color.color)
                        .frame(width: 44, height: 22)
                        .overlay {
                            DS.Radius.shape(6)
                                .stroke(DS.Chrome.separator(context), lineWidth: 1)
                        }
                    Text(name)
                        .font(DS.Text.mono)
                        .foregroundStyle(DS.Chrome.primary)
                        .frame(width: 200, alignment: .leading)
                    Text(color.hexString)
                        .dsNumeric(DS.Text.mono)
                        .foregroundStyle(DS.Chrome.secondary)
                    Spacer(minLength: 0)
                    Text(
                        String(
                            format: "%.2f:1 on canvas",
                            color.contrastRatio(against: theme.canvas)
                        )
                    )
                    .dsNumeric(DS.Text.numericCaption)
                    .foregroundStyle(DS.Chrome.tertiary)
                }
            }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Metrics")
            DetailRow("Row height", "\(Int(theme.defaultRowHeight)) pt", numeric: true)
            DetailRow("Column width", "\(Int(theme.defaultColumnWidth)) pt", numeric: true)
            DetailRow("Selection stroke", "\(theme.selectionStrokeWidth) pt", numeric: true)
            DetailRow("Card radius", "\(Int(DS.Radius.card)) pt", numeric: true)
            DetailRow("Control radius", "\(Int(DS.Radius.control)) pt", numeric: true)
            DetailRow("Cell editor radius", "\(Int(DS.Radius.cellEditor)) pt", numeric: true)
            DetailRow("Glass merge distance", "\(Int(DS.Space.glassMerge)) pt", numeric: true)
            DetailRow("Change flash", "\(Int(theme.changeFlashDuration)) s", numeric: true)
        }
    }
}

// MARK: - Previews

#Preview("Gallery") {
    GlassUIGallery()
}

#Preview("Document · dark") {
    DocumentScene(context: .dark, backdropTheme: GridTheme.resolved(.dark))
        .glassAppearance(.dark)
        .frame(width: 1120, height: 720)
}

#Preview("Document · light") {
    DocumentScene(context: .light, backdropTheme: GridTheme.resolved(.light))
        .glassAppearance(.light)
        .frame(width: 1120, height: 720)
}
