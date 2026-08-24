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
