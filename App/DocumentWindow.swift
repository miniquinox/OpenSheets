import AppKit
import DocumentCore
import GlassUI
import GridKit
import SheetFormula
import SheetModel
import SheetStore
import SwiftUI

/// The workspace window: one window, a tab per open file.
///
/// # Why there is one window and not one per file
///
/// There used to be one window per file, and everything in this file took a `DocumentModel`
/// directly. The product this app is for — watching a file an agent is editing — turned that into
/// a screen full of near-identical windows the moment more than one file was involved, with no
/// answer to "which `data.csv` is that one" short of dragging windows apart to read their titles.
///
/// So files are now **tabs** (``DocumentCore/TabsModel``) in a single window, and the tab strip
/// lives on the traffic-light line where it costs no vertical space at all. Nothing below the tab
/// changed: a tab owns a `DocumentModel` exactly as a window used to, background tabs keep their
/// watchers, and the sync machine has no idea any of this happened. What moved is *lifetime* —
/// the window's `onDisappear` used to close the document, and now ``DocumentCore/TabsModel`` does
/// (see ``releaseWorkspace()`` for the one case where this file still has to).
///
/// Explicitly out of scope for v1 (§1.1): dragging a tab out into its own window, more than one
/// workspace window, and native `NSWindow` tabbing — native tabs cannot carry a status dot or a
/// provenance tooltip, and they would stack a second bar under the custom title row.
///
/// # The layout rule this file exists to enforce
///
/// **Chrome is anchored. It occupies real space in the layout and never covers a cell.**
///
/// A5 built the components and assembled a composite to show them off; that composite floats the
/// toolbar and the formula bar over grid rows 1–5 and floats the sidebar over the toolbar's
/// leading controls. It is a good component gallery and it is not a window. PLAN.md §3 exists to
/// prevent exactly that — *"the failure mode of a glass UI is that everything floats and nothing
/// is readable"* — so here the window is a vertical stack of real rows:
///
/// ```
/// ┌═══════════════════════════════════════════════════════════┐  ═ one material, full width,
/// ║ ⦿⦿⦿  ▤  budget.xlsx │ data.csv — work    +12 ~5 ·sync· ▤  ║    from the window's top edge
/// ║ toolbar                                                   ║
/// ║ formula bar                                               ║
/// ╞══════════════┬════════════════════════════════════════════╡
/// │ sidebar      │ grid                 ·stats pill ·sync pill│  the one opaque plane
/// │ material     │                                            │
/// │ full height  ├────────────────────────────────────────────┤
/// │              │ sheet tabs — glass, on the grid's plane     │
/// └──────────────┴────────────────────────────────────────────┘
/// ```
///
/// Two things in that picture are load-bearing and were both learned the hard way.
///
/// **The band spans the full width and starts at the very top of the window.** It has to span the
/// width so the sidebar cannot clip the toolbar's leading controls. It has to start at the top
/// because the window is *not opaque* — a glass app cannot be, or its materials have nothing to
/// sample — and any strip the band does not cover is not "empty", it is a hole onto the desktop.
///
/// **The columns run the full height and inset their own content.** They used to be pushed down by
/// the band's height, which left the top-left corner belonging to nothing; that corner is exactly
/// where the wallpaper showed through. Now the sidebar's material reaches the top edge and the
/// band's material sits on top of it, so the two meet with no seam and no gap.
struct DocumentWindow: View {
    let tabs: TabsModel
    let app: AppModel
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    /// Where the traffic lights are, measured. See ``TitleBarMetrics``.
    @State private var titleBarMetrics: TitleBarMetrics = .unmeasured
    @State private var isPresentingChanges = false
    @State private var closeRequest: TabCloseRequest?

    /// What ``WorkspaceState/status(of:asOf:)`` measures "refreshed in the last six seconds"
    /// against, and the whole mechanism by which that window ever *lapses*.
    ///
    /// A dot that appears when `lastRefreshAt` is set would never go away on its own: nothing
    /// else changes six seconds later, so nothing re-evaluates this view. Rather than tick at
    /// 1 Hz forever in an app that otherwise idles, the `.task(id:)` below sleeps exactly once
    /// per refresh and then stamps this — which both re-evaluates the strip and, because the new
    /// stamp is later than the refresh, is the reason the dot goes out.
    @State private var agentDotClock = Date()

    private var context: AppearanceContext {
        appearance.context(for: colorScheme)
    }

    var body: some View {
        content
            .frame(minWidth: DS.Metrics.minimumWindowWidth, minHeight: DS.Metrics.minimumWindowHeight)
            .glassAppearance(context)
            .background(WindowConfigurator())
            // The menu bar talks to whichever window is in front. `document` is the active tab's
            // model — so ⌘S and ⌘Z reach the file the user is looking at rather than the file the
            // window was opened with — and `workspaceTabs` is what ⌘1…⌘9 and ⇧⌘] steer.
            .focusedSceneValue(\.document, tabs.activeDocument)
            .focusedSceneValue(\.workspaceTabs, tabs)
            .navigationTitle(tabs.activeDocument?.url.lastPathComponent ?? "OpenSheets")
            .onAppear {
                app.refreshMCPStatus()
                OpenActions.closeActiveTab = { closeActiveTab() }
                OpenActions.closeWorkspaceWindow = { requestCloseWindow() }
            }
            .onDisappear { releaseWorkspace() }
            .task(id: newestRefreshAt) { await lapseAgentDot() }
            // The git baseline's one call site (§1.4). `DocumentCore` ships the adapter but never
            // installs it, so without this line `gitBaselineProvider` stays nil, the model's probe
            // never runs, and *Since last commit* is a source the panel can never offer — the
            // whole of T5 and the adapter dead on the branch.
            .onChange(of: activeDocumentIdentity, initial: true) { installGitBaseline() }
            .alert(
                closeRequest?.title ?? "",
                isPresented: Binding(
                    get: { closeRequest != nil },
                    set: {
                        if !$0 {
                            closeRequest = nil
                        }
                    }
                ),
                presenting: closeRequest
            ) { request in
                Button("Save") { save(request) }
                Button("Discard", role: .destructive) { complete(request) }
                Button("Cancel", role: .cancel) { closeRequest = nil }
            } message: { request in
                Text(request.message)
            }
    }

    /// What the active tab has to show. Loading and failure are states of the **tab**, not
    /// alerts (§1.2): the user asked for this file here, so the answer belongs here, and the tab
    /// strip stays on screen and stays clickable throughout.
    @ViewBuilder
    private var content: some View {
        switch activeTab?.phase {
        case let .some(.ready(model)):
            DocumentPane(model: model, app: app, tabs: tabs, context: context) { titleBar }
        case .some(.loading):
            plane {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .some(.failed(error)):
            plane {
                EmptyStateView(
                    model: .unreadable(detail: "\(error.code): \(error.message)"),
                    context: context
                ) { action in
                    // Was `{ _ in }`. The state has offered two buttons since it was written and
                    // neither did anything — the failure mode this whole surface exists to avoid,
                    // sitting inside the screen that apologises for a failure.
                    switch action {
                    case .primary:
                        guard let url = activeTab?.url else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    case .secondary:
                        OpenActions.showOpenPanel()
                    case .showTechnicalDetail:
                        break
                    }
                }
            }
        case .none:
            // A window with no tab used to be one frame on the way out — closing the last tab
            // closed the window, so nobody sat here. Opening a *folder* made it somewhere you
            // arrive: the tree is on the left, nothing is open yet, and picking a file is the
            // next thing you do. So it draws the sidebar and says so, rather than a blank plane.
            emptyWorkspace
        }
    }

    /// A workspace with a folder open and no workbook in it.
    ///
    /// The sidebar is the point. Every other tabless state this window can be in is transient —
    /// loading, or a failed open — and draws a bare plane; this one is a place the user meant to
    /// get to, so the half of the column that works without a document is exactly what it shows.
    ///
    /// `SidebarColumn(model: nil, …)` is the whole of the difference: the sheets, named ranges,
    /// file and Claude sections need a workbook and are simply absent, while the file tree does
    /// not and is not.
    private var emptyWorkspace: some View {
        HStack(spacing: 0) {
            SidebarColumn(model: nil, app: app, context: context, topInset: titleBarMetrics.centreFromTop * 2)
            VStack(spacing: 0) {
                titleBar
                EmptyStateView(model: .noDocument, context: context) { action in
                    switch action {
                    // Both go to the open panel, which is what the launcher's own New sheet
                    // does (`LauncherScene.perform`): creating a workbook needs somewhere to put
                    // it, so the panel is the first step either way.
                    case .primary, .secondary: OpenActions.showOpenPanel()
                    case .showTechnicalDetail: break
                    }
                }
            }
        }
        .gridPlane(context)
        // As `plane`: the row belongs on the traffic-light line, not below the titlebar.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The title row over the opaque plane, for the states that have no document to build a
    /// chrome band from.
    private func plane(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            titleBar
            content()
        }
        .gridPlane(context)
        // Same reason as `DocumentPane`'s band: the row starts at the window's **top edge**, not
        // below the titlebar's safe area. Without it the title row sits a titlebar's height too
        // low and AppKit's transparent titlebar renders a blurred sample of it above — which
        // reads as the tab strip drawn twice, once ghosted, and is exactly what it is.
        .ignoresSafeArea(.container, edges: .top)
    }

    private var activeTab: TabsModel.Tab? {
        guard let id = tabs.activeTabID else { return nil }
        return tabs.tabs.first { $0.id == id }
    }

    // MARK: - The title row

    /// The window's top row — **on the traffic-light line**, not below it.
    ///
    /// # Why it is not its own band
    ///
    /// It used to be a 38pt row underneath the titlebar, which left the traffic lights sitting
    /// alone on an otherwise empty strip. That is two rows of chrome doing one row of work, and in
    /// an app whose entire job is showing as many spreadsheet rows as possible it is the most
    /// expensive kind of whitespace. Finder, Xcode, Safari and Notes all put real controls inline
    /// beside the lights; this does the same, and the grid gets the height back.
    ///
    /// # The two things that make it work
    ///
    /// **The leading inset is measured.** ``TitleBarMetrics`` reads the zoom button's frame, so
    /// the content clears the real buttons wherever the system puts them, and collapses to a plain
    /// margin in full screen when they are gone.
    ///
    /// **The empty stretches still drag the window.** Everything here is either a control or a
    /// `Spacer`, and the row draws no background of its own — the band behind it does. The metrics
    /// reader returns `nil` from `hitTest`, and `Spacer` is not hit-testable, so a click on the
    /// empty middle falls through to AppKit's titlebar and drags. Only the controls take the click.
    ///
    /// # Where the document's name went
    ///
    /// It used to sit here with a grey dot beside it for unsaved edits. The tab strip now says
    /// both, per file, for every open file — repeating the active one in the middle of the row
    /// would be the same fact twice, and it would be the half that yields first when the window
    /// narrows. `navigationTitle` still carries the name for the Window menu and the proxy icon.
    private var titleBar: some View {
        HStack(spacing: DS.Space.s) {
            Color.clear.frame(width: titleBarMetrics.leadingInset, height: DS.Stroke.hairline(context))

            titleBarToggle(
                systemImage: "sidebar.left",
                help: "Show or hide the sidebar",
                label: "Toggle sidebar"
            ) { model in model.isSidebarVisible.toggle() }

            FileTabStrip(state: tabStripState, context: context) { action in handle(action) }

            Spacer(minLength: DS.Space.s)

            // glass-lint: the changes chip and the sync chip are two separate statements — "what
            // has changed since your baseline" and "where this file stands against disk" — and
            // they must not be merged into one lens. Neither draws glass of its own; both are
            // text on the band, exactly like `SyncStateChip` has always been.
            changesControls
            syncChip

            titleBarToggle(
                systemImage: "sidebar.right",
                help: "Show or hide the inspector",
                label: "Toggle inspector"
            ) { model in model.isInspectorVisible.toggle() }
        }
        .padding(.trailing, DS.Space.m)
        // Twice the measured centre line, so the row's own centre lands exactly on the buttons'.
        .frame(height: titleBarMetrics.centreFromTop * 2)
        .background(TitleBarMetricsReader { titleBarMetrics = $0 })
        .accessibilityElement(children: .contain)
    }

    /// One glyph on the band that flips one switch on the front document.
    ///
    /// Was `paneToggle` while the sidebar and the inspector were the only two. The change
    /// highlights switch has the same shape and the same job — a display state, one tap, no
    /// confirmation — and giving it a second, near-identical helper is how a row of four buttons
    /// ends up with three different hit areas.
    private func titleBarToggle(
        systemImage: String,
        help: String,
        label: String,
        perform: @escaping (DocumentModel) -> Void
    ) -> some View {
        Button {
            guard let model = tabs.activeDocument else { return }
            perform(model)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: Self.titleGlyphSize, weight: .medium))
                .foregroundStyle(DS.Chrome.secondary)
                .frame(width: Self.titleButtonWidth, height: Self.titleButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .disabled(tabs.activeDocument == nil)
    }

    /// The counts, and the switch that turns their colour off.
    ///
    /// One `if let` and one call to ``WorkspaceState/chip(for:)`` for both, because producing the
    /// counts walks the diff: asking a second time so the button could decide its own visibility
    /// would put a second walk on every body evaluation of the title bar to learn something the
    /// first one already knew.
    ///
    /// They appear and leave together by construction, which is the intent. A switch for tints
    /// that cannot be on is a switch with nothing to do, and this row runs out of width long
    /// before it runs out of controls. When the chip is away the same switch is still in the View
    /// menu and in ⌘K — all three flip the one stored default.
    @ViewBuilder
    private var changesControls: some View {
        if let model = tabs.activeDocument, let chip = WorkspaceState.chip(for: model) {
            ChangeTrackingChip(state: chip, context: context) { isPresentingChanges = true }
                .popover(isPresented: $isPresentingChanges, arrowEdge: .bottom) {
                    ChangeTrackingPanel(state: WorkspaceState.panel(for: model), context: context) { action in
                        handle(action, on: model)
                    }
                    .glassAppearance(context)
                }
            highlightToggle(for: model)
        }
    }

    /// Keep the number, drop the paint.
    ///
    /// The counts and the tints are the same fact at two volumes, and people do not want them in
    /// the same amounts: `+12 ~5 −3` in the title bar is a thing you glance at, while a sheet
    /// stippled green and amber is a thing that will not stop talking while you are trying to read
    /// the numbers underneath it. So this turns off the drawing and leaves the chip, rather than
    /// turning off change tracking — which would make the one obvious button in the row quietly do
    /// two things, and cost the user their baseline for wanting a quieter grid.
    ///
    /// The glyph carries the state and the tooltip carries the action, because the glyph is the
    /// only part a person sees before they commit: one that looked the same either way would leave
    /// the button and the grid disagreeing about whether anything is switched on.
    ///
    /// A cell with a tint in it and the same cell empty. Not an eye — ``SyncStateChip`` is sitting
    /// two glyphs away drawing one for *Watching*, and two eyes in one row is a row where neither
    /// means anything. The dashed square is the thing being tinted, which is a narrower promise
    /// than "visibility" and happens to be the true one: this switch changes the grid's paint and
    /// nothing else about what is shown.
    private func highlightToggle(for model: DocumentModel) -> some View {
        let isOn = model.isChangeHighlightingEnabled
        return titleBarToggle(
            systemImage: isOn ? "square.dashed.inset.filled" : "square.dashed",
            help: isOn ? "Stop tinting changed cells in the grid" : "Tint changed cells in the grid",
            label: isOn ? "Hide change highlights" : "Show change highlights"
        ) { model in model.isChangeHighlightingEnabled.toggle() }
    }

    @ViewBuilder
    private var syncChip: some View {
        if let model = tabs.activeDocument {
            SyncStateChip(state: chipState(for: model), context: context) {
                switch model.syncState {
                case .stale: Task { await model.refresh() }
                case .conflict: model.showDiffPanel()
                case .dirty: Task { await model.save() }
                // Watching is the only resting state, and it needs no action: the file is
                // already being followed. Nothing to toggle, so nothing happens.
                default: break
                }
            }
        }
    }

    private var tabStripState: FileTabStripState {
        WorkspaceState.tabStrip(for: tabs, asOf: agentDotClock)
    }

    private func chipState(for model: DocumentModel) -> GlassUI.SyncState {
        SyncPresentation.chip(
            for: model.syncState,
            pendingCellCount: model.changeSet?.notice.cellCount ?? 0,
            localEditCount: model.localEditCount,
            readOnlyReason: model.workbook.meta.readOnlyReason
        )
    }

    // MARK: - The accent dot's six seconds

    /// The most recent refresh across **all** tabs, which is what the lapse timer keys on. One
    /// timer for the window rather than one per tab: the newest refresh is always the last dot to
    /// go out, so waiting for it covers every earlier one.
    private var newestRefreshAt: Date? {
        tabs.tabs.compactMap { tab -> Date? in
            guard case let .ready(model) = tab.phase else { return nil }
            return model.lastRefreshAt
        }.max()
    }

    // MARK: - The git baseline

    /// Which document the window is showing, as a value `onChange` can compare.
    ///
    /// The *object*, not the tab id: a tab activated while its file is still being read has no
    /// document yet, and keying on the id would fire once against `nil` and never again. This flips
    /// from `nil` to the model the moment the tab is ready, which is the event the install wants.
    private var activeDocumentIdentity: ObjectIdentifier? {
        tabs.activeDocument.map(ObjectIdentifier.init)
    }

    /// Gives the document on screen a way to read its own committed version.
    ///
    /// Only the active tab, and only once each. The git source is offered in the changes panel,
    /// the changes panel belongs to the tab in front, and a background tab that nobody has asked
    /// about does not need a `git rev-parse` spent on it — activating it runs this. The `nil`
    /// check is what keeps a tab switch from re-probing: installing a provider re-fires
    /// ``DocumentCore/DocumentModel``'s availability probe, which is a second `git show` and a
    /// second workbook parse for an answer that has not changed.
    private func installGitBaseline() {
        guard let model = tabs.activeDocument, model.gitBaselineProvider == nil else { return }
        GitBaselineAdapter.install(on: model)
    }

    private func lapseAgentDot() async {
        guard let newest = newestRefreshAt else { return }
        let remaining = WorkspaceState.agentDotWindow - Date().timeIntervalSince(newest)
        guard remaining > 0 else { return }
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        agentDotClock = Date()
    }

    // MARK: - Tab actions

    private func handle(_ action: FileTabAction) {
        switch action {
        case let .select(id):
            tabs.activate(id)
        case let .close(id):
            requestClose([id], closesWindow: false)
        case let .closeOthers(id):
            requestClose(tabs.tabs.map(\.id).filter { $0 != id }, closesWindow: false)
        case let .revealInFinder(id):
            guard let url = url(of: id) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case let .copyPath(id):
            guard let url = url(of: id) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path(percentEncoded: false), forType: .string)
        case .openFile:
            OpenActions.showOpenPanel()
        case .openFolder:
            openFolder()
        case let .reorder(from, to):
            tabs.move(from: from, to: to)
        }
    }

    /// Add a folder to the tree from the `+` after the last tab.
    ///
    /// **Appends.** A second folder joins the first rather than replacing it, so two unrelated
    /// trees can be open at once — the reason the `+` is here and not a "switch folder" control.
    /// Nothing about the tabs moves: the workbook in front stays in front and none of them close.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Grant first: `pin` refuses a folder no grant covers, and refuses it silently.
        // `grantWorkspace` reloads the grants synchronously, so the roots already include it.
        guard app.grantWorkspace(url) else { return }
        app.explorer.pin(url)
    }

    private func url(of id: String) -> URL? {
        tabs.tabs.first { $0.id == id }?.url
    }

    private func model(of id: String) -> DocumentModel? {
        guard let tab = tabs.tabs.first(where: { $0.id == id }),
              case let .ready(model) = tab.phase
        else { return nil }
        return model
    }

    // MARK: - Closing

    /// A close that may have to ask first.
    ///
    /// Carries the tabs rather than one tab because *Close Others* and *Close Window* are the same
    /// question asked about a set, and asking it once for the set is the difference between one
    /// panel and four.
    private struct TabCloseRequest: Identifiable {
        let id: String
        let ids: [String]
        /// File names with edits that are not on disk. Never empty — a request with nothing
        /// unsaved never becomes a panel.
        let unsaved: [String]
        /// Whether saying yes closes the whole window. A window close deliberately leaves
        /// `workspace.tabs` alone (§1.9), so relaunch brings the same tabs back; closing a tab
        /// removes it from that set, which is why the two cannot share one code path.
        let closesWindow: Bool

        var title: String {
            closesWindow
                ? "Close the window with unsaved changes?"
                : (unsaved.count == 1 ? "Close \u{201C}\(unsaved[0])\u{201D}?" : "Close \(unsaved.count) files?")
        }

        var message: String {
            "Unsaved changes in \(unsaved.joined(separator: ", ")) will be lost unless you save."
        }
    }

    private func requestClose(_ ids: [String], closesWindow: Bool) {
        let unsaved = ids.compactMap { id -> String? in
            guard let model = model(of: id), model.hasUnsavedEdits else { return nil }
            return model.url.lastPathComponent
        }
        guard !unsaved.isEmpty else {
            complete(ids: ids, closesWindow: closesWindow)
            return
        }
        closeRequest = TabCloseRequest(
            // Identity of the *question*, not of a tab: two different sets are two different
            // panels, and re-asking about the same set should reuse the one on screen.
            id: ids.joined(separator: "\n"),
            ids: ids,
            unsaved: unsaved,
            closesWindow: closesWindow
        )
    }

    private func save(_ request: TabCloseRequest) {
        closeRequest = nil
        Task {
            for id in request.ids {
                guard let model = model(of: id), model.hasUnsavedEdits else { continue }
                // A failed save keeps everything open. The reason is already on screen through
                // `lastError`, and closing anyway would be losing the work the save was for.
                guard await model.save() else { return }
            }
            complete(ids: request.ids, closesWindow: request.closesWindow)
        }
    }

    private func complete(_ request: TabCloseRequest) {
        closeRequest = nil
        complete(ids: request.ids, closesWindow: request.closesWindow)
    }

    private func complete(ids: [String], closesWindow: Bool) {
        guard !closesWindow else {
            dismiss()
            return
        }
        for id in ids {
            tabs.close(id)
        }
        // §1.2 step 9. A workspace window with no tabs is a window with nothing in it, and
        // leaving it on screen would mean the launcher can never come back.
        if tabs.isEmpty {
            dismiss()
        }
    }

    /// ⌘W. Reached from the menu bar through ``OpenActions/closeActiveTab``, because the confirm
    /// panel belongs to a window and `DocumentCommands` is not one.
    private func closeActiveTab() {
        guard let id = tabs.activeTabID else { return }
        requestClose([id], closesWindow: false)
    }

    /// ⌥⌘W.
    private func requestCloseWindow() {
        requestClose(tabs.tabs.map(\.id), closesWindow: true)
    }

    /// Window teardown.
    ///
    /// The models are released **without** going through ``DocumentCore/TabsModel/close(_:)``, and
    /// that is the entire point: `close` persists the shrinking tab set, so a window close would
    /// write an empty `workspace.tabs` and relaunch would come up with nothing (§1.9 wants the
    /// opposite — the tabs come back). Releasing directly closes each session, which is what frees
    /// the watcher's file descriptors, while the stored set stays exactly as it was.
    ///
    /// **The red button does not ask about unsaved edits**, and that is a deliberate limit rather
    /// than an oversight: `NSWindow.delegate` belongs to SwiftUI here, so there is nowhere to
    /// intercept the close and no way to cancel it once this runs. ⌥⌘W does ask. Windows closed
    /// without prompting today too, so nothing regressed — a `windowShouldClose` interception is
    /// a follow-up, and it is worth stating plainly rather than leaving as a surprise.
    private func releaseWorkspace() {
        OpenActions.workspaceClosed(tabs)
        for tab in tabs.tabs {
            guard case let .ready(model) = tab.phase else { continue }
            app.closeDocument(model)
        }
    }

    // MARK: - Change tracking

    private func handle(_ action: ChangeTrackingAction, on model: DocumentModel) {
        switch action {
        case .setCheckpoint:
            Task { await model.setCheckpoint() }
        case let .choose(choice):
            Task { await model.setBaselineSource(WorkspaceState.source(choice)) }
        case .toggleHighlights:
            model.isChangeHighlightingEnabled.toggle()
        case let .reveal(sheetName, refA1):
            reveal(sheetName: sheetName, refA1: refA1, in: model)
        case .dismiss:
            isPresentingChanges = false
        }
    }

    /// §1.8: the sheet has to exist by name and the reference has to parse. Both can fail against
    /// a diff that is a moment older than the workbook, and neither is worth a message — the row
    /// simply does not jump.
    private func reveal(sheetName: String, refA1: String, in model: DocumentModel) {
        guard let sheet = model.workbook.sheet(named: sheetName),
              let ref = CellRef(a1: refA1.uppercased())
        else { return }
        model.activeSheetID = sheet.id
        model.selection.select(ref)
        model.grid.scroll(to: ref)
    }

    // MARK: - Sizes

    /// The title row's two chevron buttons. Not spacing — the size of a specific graphic — so it
    /// is named here rather than taken off `DS.Space`.
    private static let titleGlyphSize: CGFloat = 12
    private static let titleButtonWidth: CGFloat = 24
    private static let titleButtonHeight: CGFloat = 20
}

// MARK: - One tab's document

/// Everything below the tab strip, for one document.
///
/// This was `DocumentWindow`'s whole body before tabs, and it is unchanged in behaviour: the
/// anchored band, the three columns, the palette, the staleness note, the snapshot browser and
/// the save-as exporter. What it lost is lifetime — it no longer closes the document when it goes
/// away, because a tab switch makes it go away and the background tab has to keep watching its
/// file. ``DocumentCore/TabsModel`` owns that now.
///
/// The title row arrives as a closure rather than being built here, because it is the one part of
/// the band that belongs to the *window* — the tab strip has to be the same strip whichever tab is
/// in front, and it has to survive a tab that is still loading or has failed to open.
///
/// # Anchored *and* refracting
///
/// The chrome is anchored: it has a fixed height, spans the window, and never moves. What changed
/// in Wave 2b is what is *behind* it. The grid's frame now starts at the toolbar's top edge and
/// gives that height straight back as scroll inset (``GridKit/GridOptions/contentInsets``), so:
///
/// - at rest, row 1 sits immediately below the formula bar — the layout is identical to a stack;
/// - as you scroll, real cells pass under the glass, and `.backgroundExtensionEffect()` finally
///   has something to extend. Chrome over a flat window background reads as a grey rectangle, and
///   that is exactly what the first round of screenshots showed.
///
/// This is **not** A5's composite floating a panel over rows 1–5. The difference is permanence: an
/// overlay hides those rows for good, an inset hides nothing — the reserved band is scroll range,
/// so every cell is one scroll away, which is how Numbers and every native app of this shape
/// behaves. The sidebar and the inspector run *under* the band rather than starting below it, but
/// only their material does: their content is inset by the same measured height, so nothing is
/// covered and there is no second lens stacked on the first.
///
/// Which surface gets which treatment is not a style choice — see ``GlassUI/ChromeVibrancy``.
/// Edge bands take a **material** (`NSVisualEffectView`), because they border the desktop and a
/// lens over the desktop is a window. Floating surfaces take **glass**, because the grid is behind
/// them and a lens needs something to refract. The grid takes neither.
///
/// **Exactly three things float**: the selection stats pill, the refresh pill / diff panel, and
/// the ⌘K palette. The first two live in the grid's bottom corners, over the reserved bottom
/// inset, so they never cover a cell that cannot be scrolled out from under them.
private struct DocumentPane<TitleBar: View>: View {
    @Bindable var model: DocumentModel
    let app: AppModel
    /// The window's tabs, for the two palette verbs that steer them.
    ///
    /// A pane that is *about* one document holding the whole tab set looks like a layering slip
    /// and is not one: the ⌘K palette is a window-level command surface that happens to be drawn
    /// inside the pane, and `Next tab` in the palette has to be the same call the menu bar makes.
    /// The alternative was another `OpenActions` static, which is what that file's own doc comment
    /// calls the last resort — statics are there for the callers that *cannot* be handed a value,
    /// and this one is constructed two lines up from the tabs it needs.
    let tabs: TabsModel
    let context: AppearanceContext
    @ViewBuilder var titleBar: () -> TitleBar

    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [SnapshotRecord] = []
    @State private var isPresentingSaveAs = false
    @State private var paletteState = CommandPaletteState()
    @State private var paletteCommands: [String: PaletteCommand] = [:]
    /// The measured height of the anchored chrome, handed to the grid as a scroll inset so the
    /// two can never disagree about where row 1 begins.
    @State private var chromeHeight: CGFloat = 0
    /// The sheet tab plate's height, measured like `chromeHeight`: the floating agents' collapsed
    /// shapes sit this much higher, so their gap to the plate's hairline equals their gap to the
    /// window's right edge — the two boundaries the eye actually measures them against.
    @State private var plateHeight: CGFloat = 0

    var body: some View {
        Group {
            if let empty = emptyState {
                VStack(spacing: 0) {
                    titleBar()
                    EmptyStateView(model: empty, context: context) { action in
                        handle(empty, action)
                    }
                }
                .gridPlane(context)
                // The band below does this; so must the branch that replaces it, or an
                // unreadable file draws its title row a titlebar too low.
                .ignoresSafeArea(.container, edges: .top)
            } else {
                // One ZStack, not a VStack of bands: the columns run the **full height of the
                // window** and the chrome floats over them. That is what lets the sidebar's
                // material reach the top edge, which is the difference between a band and a hole
                // — see `chrome` and ``GlassUI/ChromeVibrancy``.
                ZStack(alignment: .top) {
                    split
                    chrome
                }
                // The band starts at the window's **top edge**, not below the titlebar's safe
                // area. That is what puts the title row on the traffic-light line instead of
                // under it, and it keeps one coordinate space for the whole window: `chromeHeight`
                // is measured from the top edge, and the columns and the grid inset by it.
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .overlay { palette }
        .overlay(alignment: .top) { stalenessNote }
        .onChange(of: model.needsSaveAs) { _, needed in isPresentingSaveAs = needed }
        .fileExporter(
            isPresented: $isPresentingSaveAs,
            document: WorkbookExport(),
            contentType: .data,
            defaultFilename: model.url.deletingPathExtension().lastPathComponent
        ) { result in
            if case let .success(destination) = result {
                Task { try? await model.saveAs(to: destination) }
            }
        }
        .onChange(of: model.isPresentingSnapshots) { _, presenting in
            guard presenting else { return }
            Task { snapshots = await model.snapshots() }
        }
        .sheet(isPresented: $model.isPresentingSnapshots) {
            SnapshotBrowser(
                state: snapshotState,
                context: context
            ) { action in
                handle(action)
            }
            .padding(DS.Space.xl)
            .glassAppearance(context)
        }
    }

    // MARK: - Anchored chrome

    /// The title row, the toolbar and the formula bar, as **one** anchored band on **one**
    /// material.
    ///
    /// # Why all three are one surface
    ///
    /// They used to be three things: a titlebar row in the outer stack, then a toolbar and a
    /// formula bar sharing a `VStack` with no backing of their own. That worked only because the
    /// window painted an opaque rectangle behind the entire content. The moment the window stopped
    /// doing that — which is what a glass app has to do, or there is nothing for a material to
    /// sample — each of them turned into a clear hole onto the desktop, with the wallpaper legible
    /// between the toolbar buttons and behind the document title.
    ///
    /// So the band is a single ``GlassUI/ChromeVibrancy/band`` surface that spans the full window
    /// width and runs from the very top of the window to the bottom of the formula bar. The
    /// per-control glass capsules in `ToolbarSurface` sit *on* it; they were never a substitute
    /// for it.
    ///
    /// # Measured, not sized
    ///
    /// The grid insets its scroll range by this band's height, so hardcoding one would show up as
    /// row 1 sitting half under the formula bar. It is measured, and now that the title row is
    /// part of the same stack the measurement covers it too — which is what let two eyeballed
    /// `120` and `132` offsets elsewhere in this file become `chromeHeight` plus a token.
    private var chrome: some View {
        VStack(spacing: 0) {
            titleBar()

            ToolbarSurface(state: model.toolbar, context: context) { action in
                perform(action)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Vertical rhythm of its own. Without it the toolbar's capsules touch the title row
            // above and the formula bar below, and the band reads as three things jammed together
            // rather than one surface.
            .padding(.vertical, DS.Space.xs)
            .background(alignment: .bottom) { hairline }

            FormulaBar(state: model.formulaBar, context: context) { action in
                perform(action)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(alignment: .bottom) { hairline }
        }
        .vibrantChrome(.band, context: context)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            chromeHeight = height
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(DS.Chrome.separator(context))
            .frame(height: DS.Stroke.hairline(context))
    }

    // MARK: - The split

    /// The three columns, **every one of them full height**.
    ///
    /// Each column used to be pushed down by `.padding(.top, chromeHeight)` so it would start
    /// below the band. That left the top-left corner of the window — the strip above the sidebar —
    /// belonging to nothing at all, which is exactly where the desktop showed through once the
    /// window's opaque backing was removed.
    ///
    /// Now the *surfaces* run edge to edge and each column insets its own *content* instead. The
    /// sidebar's material therefore reaches the top of the window and the band's material sits on
    /// top of it, so there is no seam and no gap — the arrangement Finder, Mail and Xcode all use.
    ///
    /// **There is no divider column here.** Each chrome column draws the hairline on its own edge,
    /// through ``GlassUI/SwiftUI/View/vibrantChrome(_:context:separator:)``. A `Rectangle` between
    /// two columns is a third region with no material behind it, and `DS.Chrome.separator` is
    /// semi-transparent — so it was a bright stripe of wallpaper running the full height of the
    /// window. Third time that shape of bug appeared here; the fix is structural rather than a
    /// darker colour.
    private var split: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarColumn(model: model, app: app, context: context, topInset: chromeHeight)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            // The one opaque plane. Its scroll insets give the band's height back, so no cell is
            // hidden by chrome — see `GridPane`.
            VStack(spacing: 0) {
                GridPane(model: model, context: context, chromeInset: chromeHeight)
                SheetTabPlate(model: model, context: context)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        plateHeight = height
                    }
            }
            // The agent surfaces float on the *document area*, not inside the grid, so their
            // margins answer to the window. One rule, two phases: a collapsed pill or bubble
            // rests in the grid's corner, lifted clear of the tab plate so its gap to the
            // plate's hairline equals its gap to the window's right edge; an expanded panel
            // drops to one `floatingInset` off the window's bottom, over the plate's empty end —
            // the system-HUD plane, where the volume control lives. Straddling was tried and
            // looked broken: a bubble crossing the plate's hairline reads as misaligned even
            // when its margins measure equal, because the eye measures to the nearest line.
            .overlay(alignment: .bottomTrailing) { floatingAgents }
            if model.isInspectorVisible {
                InspectorColumn(model: model, context: context, topInset: chromeHeight)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(DS.Motion.standard, value: model.isSidebarVisible)
        .animation(DS.Motion.standard, value: model.isInspectorVisible)
    }

    // MARK: - Floating: the palette

    @ViewBuilder
    private var palette: some View {
        if model.isPaletteVisible {
            ZStack {
                Color.black.opacity(PaneMetrics.scrimOpacity)
                    .ignoresSafeArea()
                    .onTapGesture { model.isPaletteVisible = false }
                CommandPalette(state: paletteState, context: context) { action in
                    handle(action)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                // Was an eyeballed 120. The palette hangs below the anchored band, and the band
                // measures itself — so this is that measurement plus one step of air, and it
                // stays right when a control size or a font changes.
                .padding(.top, chromeHeight + DS.Space.xl)
            }
            .transition(.opacity)
            .onAppear { rebuildPalette() }
        }
    }

    /// The one-time note that this workbook has a chart or a pivot whose cached values an edit
    /// does not update (addendum §5). Anchored under the formula bar, dismissible, once a session.
    @ViewBuilder
    private var stalenessNote: some View {
        if let notice = model.stalenessWarning, let reason = notice.reasons.first {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: "info.circle")
                    .foregroundStyle(DS.Signal.staleInk(context))
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text(reason.headline).font(DS.Text.controlEmphasis)
                    Text(reason.detail)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Got it") { model.dismissStalenessWarning() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: PaneMetrics.stalenessNoteWidth)
            .glassCard(context: context, radius: DS.Radius.panel)
            // Was an eyeballed 132 — 12 more than the palette's 120, which is what compensating
            // for an unmeasured chrome height looks like. Same measurement, tighter air, because
            // this note is anchored *to* the formula bar rather than floating below it.
            .padding(.top, chromeHeight + DS.Space.s)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The sync surface and the sheet chat, sharing the document-area corner — see the overlay
    /// site for the two-phase rule. Not one `GlassCluster`: the app asking for a decision and an
    /// assistant waiting to be asked are different statements, and must never merge into one lens.
    private var floatingAgents: some View {
        HStack(alignment: .bottom, spacing: DS.Space.xxl) {
            if let changeSet = model.changeSet {
                SyncSurface(
                    phase: model.syncPhase,
                    changeSet: changeSet,
                    filteredSheet: model.diffSheetFilter,
                    context: context
                ) { action in
                    Task { await model.handle(action) }
                }
                .padding(.bottom, model.syncPhase == .panel ? 0 : plateHeight)
            }

            if Flags.chatEnabled {
                ChatSurface(
                    phase: model.isChatVisible ? .panel : .bubble,
                    state: model.chat.surfaceState,
                    context: context
                ) { action in
                    switch action {
                    case .expand: model.isChatVisible = true
                    case .collapse: model.isChatVisible = false
                    case let .send(text): model.chat.send(text)
                    case .stop: model.chat.stop()
                    case .clear: model.chat.clearConversation()
                    }
                }
                .padding(.bottom, model.isChatVisible ? 0 : plateHeight)
            }
        }
        .padding(DS.Space.floatingInset)
        .animation(DS.Motion.morph(context), value: model.isChatVisible)
        .animation(DS.Motion.morph(context), value: model.syncPhase)
    }

    // MARK: - States

    private var emptyState: EmptyStateModel? {
        SyncPresentation.emptyState(
            for: model.syncState,
            fileName: model.url.lastPathComponent,
            sheetCount: model.workbook.sheets.count,
            readOnlyReason: model.workbook.meta.readOnlyReason,
            lastError: model.lastError
        )
    }

    private var snapshotState: SnapshotBrowserState {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let relative = RelativeDateTimeFormatter()
        return SnapshotBrowserState(
            entries: snapshots.map { record in
                SnapshotEntry(
                    id: record.id.rawValue,
                    takenAt: formatter.string(from: record.takenAt),
                    relative: relative.localizedString(for: record.takenAt, relativeTo: Date()),
                    reason: GlassUI.SnapshotReason(rawValue: record.reason.rawValue) ?? .manual,
                    summary: record.summary ?? "\(record.byteCount.formatted(.byteCount(style: .file)))",
                    size: record.compressedByteCount.formatted(.byteCount(style: .file))
                )
            },
            storageSummary: "\(snapshots.count) of \(Limits.maxSnapshotsPerFile) kept"
        )
    }

    // MARK: - Actions

    private func handle(_ empty: EmptyStateModel, _ action: EmptyStateAction) {
        switch action {
        case .primary:
            if model.syncState == .missing {
                isPresentingSaveAs = true
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([model.url])
            }
        case .secondary:
            dismiss()
        case .showTechnicalDetail:
            break
        }
    }

    private func handle(_ action: SnapshotBrowserAction) {
        switch action {
        case let .restore(id):
            guard let ulid = ULID(rawValue: id) else { return }
            model.isPresentingSnapshots = false
            Task { await model.restore(ulid) }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([model.url])
        case .dismiss:
            model.isPresentingSnapshots = false
        default:
            break
        }
    }

    private func handle(_ action: CommandPaletteAction) {
        switch action {
        case let .queryChanged(query):
            paletteState.query = query
            rebuildPalette()
        case let .moveSelection(delta):
            let items = paletteState.allItems
            guard !items.isEmpty else { return }
            let current = items.firstIndex { $0.id == paletteState.selectedID } ?? 0
            let next = (current + delta + items.count) % items.count
            paletteState.selectedID = items[next].id
        case let .run(id):
            model.isPaletteVisible = false
            guard let command = paletteCommands[id] else { return }
            run(command)
        case .dismiss:
            model.isPaletteVisible = false
        }
    }

    private func rebuildPalette() {
        let built = CommandRegistry.sections(
            query: paletteState.query,
            workbook: model.workbook,
            definedNames: model.definedNameItems,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            canRefresh: model.syncState == .stale || model.syncState == .synced,
            canSave: model.syncState.allowsSaving && model.hasUnsavedEdits,
            isTrackingChanges: Flags.changeTrackingEnabled,
            hasTabs: tabs.tabs.count > 1,
            hasChat: Flags.chatEnabled
        )
        paletteState.sections = built.sections
        paletteCommands = built.commands
        paletteState.selectedID = built.sections.first?.items.first?.id
    }

    private func run(_ command: PaletteCommand) {
        switch command {
        case let .goToCell(ref):
            model.selection.select(ref)
            model.grid.scroll(to: ref)
        case let .selectSheet(id):
            model.activeSheetID = id
        case let .selectDefinedName(name):
            selectDefinedName(name)
        case .refresh:
            Task { await model.refresh() }
        case .save:
            Task { await model.save() }
        case .undo:
            model.undo()
        case .redo:
            model.redo()
        case .toggleSidebar:
            model.isSidebarVisible.toggle()
        case .toggleInspector:
            model.isInspectorVisible.toggle()
        case .toggleFormulas:
            model.showsFormulas.toggle()
        case .snapshots:
            model.isPresentingSnapshots = true
        case .openTerminal:
            TerminalLauncher.open(at: model.workspaceURL)
        case .insertFunction:
            break
        // The same four calls the menu bar and the changes panel make. Deliberately not a
        // shortcut into some palette-only path: a command that behaves differently depending on
        // which surface invoked it is a command with two behaviours to keep in step.
        case .setCheckpoint:
            Task { await model.setCheckpoint() }
        case .toggleChangeHighlights:
            model.isChangeHighlightingEnabled.toggle()
        case .nextTab:
            tabs.activateNext()
        case .previousTab:
            tabs.activatePrevious()
        case .toggleChat:
            model.isChatVisible.toggle()
        }
    }

    private func selectDefinedName(_ name: String) {
        guard let defined = model.workbook.definedName(name) ?? model.workbook.definedNames[name],
              let target = defined.target
        else { return }
        if let sheet = target.sheet {
            model.activeSheetID = sheet
        }
        model.selection.select(target.range, active: target.range.start)
        model.grid.scroll(to: target.range.start)
    }

    private func perform(_ action: ToolbarAction) {
        switch action {
        case .cut: model.copy(cut: true)
        case .copy: model.copy()
        case .paste: model.paste()
        case .pasteValuesOnly: model.paste(.valuesOnly)
        case .pasteFormatsOnly: model.paste(.formatsOnly)
        case .toggleBold: model.restyle("Bold") { $0.font.isBold.toggle() }
        case .toggleItalic: model.restyle("Italic") { $0.font.isItalic.toggle() }
        case .toggleUnderline:
            model.restyle("Underline") { $0.font.underline = $0.font.underline == .none ? .single : .none }
        case let .setFontName(name): model.restyle("Font") { $0.font.name = name }
        case let .setFontSize(size): model.restyle("Font size") { $0.font.size = size }
        case let .setAlignment(align): model.restyle("Alignment") { $0.alignment.horizontal = horizontal(align) }
        case .toggleWrapText: model.restyle("Wrap text") { $0.alignment.wrapText.toggle() }
        case let .setTextColor(color): model.restyle("Text colour") { $0.font.color = color }
        case let .setFillColor(color):
            // `.none`, not a white fill: xlsx distinguishes "no pattern" from "solid white", and
            // only the first lets a banded row or a conditional format show through underneath.
            model.restyle("Fill colour") { $0.fill = color.map(FillStyle.solid) ?? .none }
        case .toggleMerge: model.toggleMerge()
        case let .setNumberFormat(choice):
            model.restyle("Number format") { $0.numberFormatID = formatID(choice) }
        case .increaseDecimals: model.adjustDecimals(by: 1)
        case .decreaseDecimals: model.adjustDecimals(by: -1)
        case .insertRows: model.structural(.insertRows)
        case .insertColumns: model.structural(.insertColumns)
        case .deleteRows: model.structural(.deleteRows)
        case .deleteColumns: model.structural(.deleteColumns)
        case let .autoSum(function): model.autoSum(function)
        // Find and replace is v0.4 (PLAN.md §11). Until then the magnifier opens the palette,
        // which does go-to-cell, sheets and named ranges — an honest subset rather than a control
        // that looks like search and does nothing.
        case .find: model.isPaletteVisible = true
        case .sortAscending: model.sort(ascending: true)
        case .sortDescending: model.sort(ascending: false)
        case .toggleFilter: break
        }
    }

    /// The formula bar's actions, all of which are the document's business rather than the view's.
    ///
    /// `.beginEditing` used to call `model.grid.beginEdit()`, which starts editing **in the cell**
    /// — so clicking the bar opened an editor somewhere else and left the bar looking inert, which
    /// is what the bug was reported as. `.textChanged` used to be `break`, so anything typed there
    /// went nowhere. Both now go to the document, and the commit goes through
    /// ``DocumentCore/DocumentModel/commitEdit(at:text:advance:selectionBefore:)`` — the same call
    /// an in-cell commit arrives on, so there is exactly one write path.
    /// The four editing actions belong to
    /// ``DocumentCore/DocumentModel/perform(_:)``, which is where they can be tested against a
    /// real workbook. What is left here is what genuinely needs the window: navigation, which
    /// wants the palette's list of defined names.
    private func perform(_ action: FormulaBarAction) {
        guard !model.perform(action) else { return }
        switch action {
        case let .navigate(text), let .selectDefinedName(text):
            if let ref = CellRef(a1: text.uppercased()) {
                model.selection.select(ref)
                model.grid.scroll(to: ref)
            } else {
                selectDefinedName(text)
            }
        case .insertFunction, .toggleExpanded:
            break
        case .beginEditing, .textChanged, .commit, .cancel:
            break
        }
    }

    private func horizontal(_ align: CellAlign) -> CellAlignment.Horizontal {
        switch align {
        case .general: .general
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    private func formatID(_ choice: NumberFormatChoice) -> Int32 {
        switch choice {
        case .general: 0
        case .number: 4
        case .currency: 44
        case .percent: 10
        case .scientific: 11
        case .date: 14
        case .text: 49
        }
    }
}

/// ``DocumentPane``'s two measured constants.
///
/// Outside the view because `DocumentPane` is generic over the title row it hosts, and Swift has
/// no static storage in a generic type. A named enum is the better home anyway: these are the two
/// numbers in this file that are neither on the spacing scale nor measured from the window, and
/// keeping them together is what makes that obvious.
private enum PaneMetrics {
    /// How far the palette dims the window behind it. Not spacing, and not a colour token — it is
    /// the strength of one specific scrim, and A5's value.
    static let scrimOpacity = 0.18

    /// The staleness note reads as a paragraph, so it is capped at a comfortable measure rather
    /// than stretched to the window.
    static let stalenessNoteWidth: CGFloat = 520
}
