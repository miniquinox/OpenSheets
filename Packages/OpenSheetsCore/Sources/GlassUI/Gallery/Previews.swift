import SwiftUI

/// Every component, light and dark, over a real grid.
///
/// The previews live in one file rather than next to each component on purpose. A `#Preview` at
/// the bottom of `Sidebar.swift` shows you the sidebar; what you actually need to see is the
/// sidebar *over a spreadsheet*, at the right size, in both schemes — which is the same four lines
/// of scaffolding every time. ``PreviewStage`` is those four lines, and having them in one place
/// means a new component gets a correct preview by writing one line rather than by copying five.
///
/// ``GlassUIGallery`` remains the real review surface; these are for the inner loop.
struct PreviewStage<Content: View>: View {
    let context: AppearanceContext
    var width: CGFloat = 900
    var height: CGFloat = 520
    @ViewBuilder var content: (AppearanceContext) -> Content

    var body: some View {
        ZStack {
            MockGrid(theme: GridTheme.resolved(context))
                .gridPlane(context)
            content(context)
                .padding(DS.Space.xxl)
        }
        .glassAppearance(context)
        .frame(width: width, height: height)
    }
}

/// Fixtures for the file-tab strip and the change-tracking pair.
///
/// Separate from ``Mock`` because that one tells a single consistent story — one refresh, 42 cells,
/// on the sheet called Q4 — and `ComponentModelTests` asserts it stays consistent. These are
/// deliberately *inconsistent* with each other: each one exists to put a component in one specific
/// state that is otherwise hard to reach, including several that only occur when something has gone
/// wrong.
enum TabsMock {
    static let single = FileTabStripState(
        tabs: [
            FileTabItem(id: "1", title: "budget.xlsx", fullPath: "/Users/q/work/budget.xlsx"),
        ],
        activeID: "1"
    )

    /// Every status at once, which never happens in life and is the only way to review them.
    static let everyStatus = FileTabStripState(
        tabs: [
            FileTabItem(id: "1", title: "budget.xlsx", fullPath: "/Users/q/work/budget.xlsx"),
            FileTabItem(
                id: "2", title: "forecast.csv", fullPath: "/Users/q/models/forecast.csv",
                status: .agentChanged
            ),
            FileTabItem(
                id: "3", title: "payroll.xlsx", fullPath: "/Users/q/work/payroll.xlsx",
                status: .unsaved
            ),
            FileTabItem(
                id: "4", title: "ledger.xlsx", fullPath: "/Users/q/work/ledger.xlsx",
                status: .conflict
            ),
            FileTabItem(
                id: "5", title: "gone.csv", fullPath: "/Users/q/work/gone.csv",
                status: .problem
            ),
            FileTabItem(
                id: "6", title: "opening.xlsx", fullPath: "/Users/q/work/opening.xlsx",
                status: .loading
            ),
        ],
        activeID: "2"
    )

    /// Two files with one name. The disambiguator appears on **both**, because a folder name on
    /// one of them would read as a property of that file rather than as a distinction.
    static let collision = FileTabStripState(
        tabs: [
            FileTabItem(
                id: "1", title: "data.csv", disambiguator: "work",
                fullPath: "/Users/q/work/data.csv"
            ),
            FileTabItem(
                id: "2", title: "data.csv", disambiguator: "models",
                fullPath: "/Users/q/models/data.csv", status: .agentChanged
            ),
            FileTabItem(id: "3", title: "notes.csv", fullPath: "/Users/q/work/notes.csv"),
        ],
        activeID: "1"
    )

    static let many = FileTabStripState(
        tabs: (1 ... 12).map { index in
            FileTabItem(
                id: "\(index)",
                title: "quarter-\(index).xlsx",
                fullPath: "/Users/q/work/quarter-\(index).xlsx",
                status: index == 4 ? .agentChanged : .none
            )
        },
        activeID: "4"
    )

    static let counts = ChangeTrackingChipState(added: 12, modified: 5, removed: 3)

    static let truncatedCounts = ChangeTrackingChipState(
        added: 500, modified: 128, removed: 4, isTruncated: true
    )

    static let panel = ChangeTrackingPanelState(
        chip: counts,
        baselineLabel: "Since opened · 09:41",
        styleOnlyCount: 7,
        sections: [
            ChangeTrackingPanelState.Section(
                id: "Q4", sheetName: "Q4",
                rows: [
                    .init(id: "Q4!D2", sheetName: "Q4", refA1: "D2", summary: "120 → 129.6", kind: .modified),
                    .init(id: "Q4!D3", sheetName: "Q4", refA1: "D3", summary: "98 → 105.8", kind: .modified),
                    .init(id: "Q4!E7", sheetName: "Q4", refA1: "E7", summary: "= SUM(D2:D6)", kind: .added),
                    .init(
                        id: "structural-Q4-rows-5", sheetName: "Q4",
                        summary: "inserted 1 row at 5", kind: .structural
                    ),
                ],
                omittedCount: 3
            ),
            ChangeTrackingPanelState.Section(
                id: "Summary", sheetName: "Summary",
                rows: [
                    .init(id: "Summary!B4", sheetName: "Summary", refA1: "B4", summary: "gone", kind: .removed),
                ]
            ),
        ]
    )

    static let panelWithGit = ChangeTrackingPanelState(
        chip: counts,
        baselineLabel: "Since a1b2c3d",
        highlightsEnabled: false,
        sources: [.asOpened, .checkpoint, .gitHEAD],
        activeSource: .gitHEAD,
        sections: panel.sections
    )

    static let panelAfterCheckpoint = ChangeTrackingPanelState(
        chip: ChangeTrackingChipState(),
        baselineLabel: "Since checkpoint · 12:03",
        activeSource: .checkpoint
    )

    static let panelTruncated = ChangeTrackingPanelState(
        chip: truncatedCounts,
        baselineLabel: "Since opened · 09:41"
    )
}

#Preview("Toolbar · light") {
    PreviewStage(context: .light, height: 200) { context in
        ToolbarSurface(state: Mock.toolbar, context: context) { _ in }
    }
}

#Preview("Toolbar · dark") {
    PreviewStage(context: .dark, height: 200) { context in
        ToolbarSurface(state: Mock.toolbar, context: context) { _ in }
    }
}

#Preview("Formula bar · light") {
    PreviewStage(context: .light, height: 260) { context in
        GlassCluster {
            VStack(spacing: DS.Space.l) {
                FormulaBar(state: Mock.formulaBar, context: context) { _ in }
                FormulaBar(state: Mock.formulaBarLiteral, context: context) { _ in }
                FormulaBar(state: Mock.formulaBarWithError, context: context) { _ in }
            }
        }
    }
}

#Preview("Formula bar · dark") {
    PreviewStage(context: .dark, height: 260) { context in
        GlassCluster {
            VStack(spacing: DS.Space.l) {
                FormulaBar(state: Mock.formulaBar, context: context) { _ in }
                FormulaBar(state: Mock.formulaBarLiteral, context: context) { _ in }
                FormulaBar(state: Mock.formulaBarWithError, context: context) { _ in }
            }
        }
    }
}

#Preview("Sheet tabs · light") {
    PreviewStage(context: .light, height: 180) { context in
        SheetTabBar(state: Mock.tabBar, context: context) { _ in }
    }
}

#Preview("Sheet tabs · dark") {
    PreviewStage(context: .dark, height: 180) { context in
        SheetTabBar(state: Mock.tabBar, context: context) { _ in }
    }
}

#Preview("File tabs · light") {
    PreviewStage(context: .light, height: 180) { context in
        FileTabStrip(state: TabsMock.everyStatus, context: context) { _ in }
    }
}

#Preview("File tabs · dark") {
    PreviewStage(context: .dark, height: 180) { context in
        FileTabStrip(state: TabsMock.everyStatus, context: context) { _ in }
    }
}

#Preview("File tabs · one file") {
    // The everyday shape, and the one the strip has to look deliberate in: a single tab should
    // read as "this is the file", not as a control waiting for more of itself.
    PreviewStage(context: .light, height: 180) { context in
        FileTabStrip(state: TabsMock.single, context: context) { _ in }
    }
}

#Preview("File tabs · duplicate names") {
    PreviewStage(context: .light, height: 180) { context in
        FileTabStrip(state: TabsMock.collision, context: context) { _ in }
    }
}

#Preview("File tabs · overflow") {
    // Narrow on purpose. This is the case the content-width cap exists for: the strip hugs its
    // tabs until they do not fit, and only then starts scrolling.
    PreviewStage(context: .dark, width: 520, height: 180) { context in
        FileTabStrip(state: TabsMock.many, context: context) { _ in }
    }
}

#Preview("Changes chip · light") {
    PreviewStage(context: .light, height: 160) { context in
        ChangeTrackingChip(state: TabsMock.counts, context: context) {}
    }
}

#Preview("Changes chip · dark") {
    PreviewStage(context: .dark, height: 160) { context in
        ChangeTrackingChip(state: TabsMock.truncatedCounts, context: context) {}
    }
}

#Preview("Changes panel · light") {
    PreviewStage(context: .light, height: 620) { context in
        ChangeTrackingPanel(state: TabsMock.panel, context: context) { _ in }
    }
}

#Preview("Changes panel · dark") {
    PreviewStage(context: .dark, height: 620) { context in
        ChangeTrackingPanel(state: TabsMock.panel, context: context) { _ in }
    }
}

#Preview("Changes panel · git offered") {
    PreviewStage(context: .light, height: 620) { context in
        ChangeTrackingPanel(state: TabsMock.panelWithGit, context: context) { _ in }
    }
}

#Preview("Changes panel · nothing since checkpoint") {
    // What the panel looks like immediately after Set Checkpoint — the reward state, and the one
    // that is easiest to leave looking like an error.
    PreviewStage(context: .dark, height: 420) { context in
        ChangeTrackingPanel(state: TabsMock.panelAfterCheckpoint, context: context) { _ in }
    }
}

#Preview("Changes panel · truncated") {
    PreviewStage(context: .light, height: 420) { context in
        ChangeTrackingPanel(state: TabsMock.panelTruncated, context: context) { _ in }
    }
}

#Preview("Sidebar · light") {
    PreviewStage(context: .light, width: 640, height: 720) { context in
        HStack {
            Sidebar(state: Mock.sidebar, context: context) { _ in }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Sidebar · dark") {
    PreviewStage(context: .dark, width: 640, height: 720) { context in
        HStack {
            Sidebar(state: Mock.sidebar, context: context) { _ in }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Refresh pill · light") {
    PreviewStage(context: .light, height: 300) { context in
        GlassCluster {
            VStack(spacing: DS.Space.l) {
                RefreshPill(notice: Mock.notice, context: context) { _ in }
                RefreshPill(notice: Mock.conflictNotice, context: context) { _ in }
                RefreshPill(notice: Mock.failureNotice, context: context) { _ in }
            }
        }
    }
}

#Preview("Refresh pill · dark") {
    PreviewStage(context: .dark, height: 300) { context in
        GlassCluster {
            VStack(spacing: DS.Space.l) {
                RefreshPill(notice: Mock.notice, context: context) { _ in }
                RefreshPill(notice: Mock.conflictNotice, context: context) { _ in }
                RefreshPill(notice: Mock.failureNotice, context: context) { _ in }
            }
        }
    }
}

#Preview("Diff panel · light") {
    PreviewStage(context: .light, height: 620) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}

#Preview("Diff panel · dark") {
    PreviewStage(context: .dark, height: 620) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}

#Preview("Conflict banner · light") {
    PreviewStage(context: .light, height: 220) { context in
        ConflictBanner(model: Mock.conflict, context: context) { _ in }
    }
}

#Preview("Conflict banner · dark") {
    PreviewStage(context: .dark, height: 220) { context in
        ConflictBanner(model: Mock.conflict, context: context) { _ in }
    }
}

#Preview("Selection stats · light") {
    PreviewStage(context: .light, height: 180) { context in
        SelectionStatsPill(stats: Mock.selectionStats, context: context) { _ in }
    }
}

#Preview("Selection stats · dark") {
    PreviewStage(context: .dark, height: 180) { context in
        SelectionStatsPill(stats: Mock.selectionStats, context: context) { _ in }
    }
}

#Preview("Command palette · light") {
    PreviewStage(context: .light, height: 620) { context in
        CommandPalette(state: Mock.commandPalette, context: context) { _ in }
    }
}

#Preview("Command palette · dark") {
    PreviewStage(context: .dark, height: 620) { context in
        CommandPalette(state: Mock.commandPalette, context: context) { _ in }
    }
}

#Preview("Inspector · light") {
    PreviewStage(context: .light, width: 640, height: 700) { context in
        HStack {
            Spacer(minLength: 0)
            Inspector(state: Mock.inspector, context: context) { _ in }
        }
    }
}

#Preview("Inspector · dark") {
    PreviewStage(context: .dark, width: 640, height: 700) { context in
        HStack {
            Spacer(minLength: 0)
            Inspector(state: Mock.inspector, context: context) { _ in }
        }
    }
}

#Preview("Snapshots · light") {
    PreviewStage(context: .light, height: 560) { context in
        SnapshotBrowser(state: Mock.snapshots, context: context) { _ in }
    }
}

#Preview("Snapshots · dark") {
    PreviewStage(context: .dark, height: 560) { context in
        SnapshotBrowser(state: Mock.snapshots, context: context) { _ in }
    }
}

#Preview("Launcher · light") {
    LauncherWindow(state: Mock.launcher, context: .light) { _ in }
        .glassAppearance(.light)
        .padding(DS.Space.xxl)
}

#Preview("Launcher · dark") {
    LauncherWindow(state: Mock.launcher, context: .dark) { _ in }
        .glassAppearance(.dark)
        .padding(DS.Space.xxl)
}

#Preview("Empty states · light") {
    PreviewStage(context: .light, height: 460) { context in
        EmptyStateView(model: .unreadable(detail: "zip.pathTraversal(\"../etc/passwd\")"), context: context) { _ in }
    }
}

#Preview("Empty states · dark") {
    PreviewStage(context: .dark, height: 460) { context in
        EmptyStateView(model: .fileMissing(name: Mock.fileName), context: context) { _ in }
    }
}

#Preview("Reduce transparency · light") {
    PreviewStage(
        context: AppearanceContext(colorScheme: .light, reduceTransparency: true),
        height: 620
    ) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}

#Preview("Reduce transparency · dark") {
    PreviewStage(
        context: AppearanceContext(colorScheme: .dark, reduceTransparency: true),
        height: 620
    ) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}

#Preview("Increase contrast · light") {
    PreviewStage(
        context: AppearanceContext(colorScheme: .light, increaseContrast: true),
        height: 620
    ) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}

#Preview("Increase contrast · dark") {
    PreviewStage(
        context: AppearanceContext(colorScheme: .dark, increaseContrast: true),
        height: 620
    ) { context in
        DiffPanel(changeSet: Mock.changeSet, context: context) { _ in }
    }
}
