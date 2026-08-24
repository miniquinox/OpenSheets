import AppKit
import DocumentCore
import GlassUI
import GridKit
import SheetFormula
import SheetModel
import SheetStore
import SwiftUI

/// The document window.
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
/// ║ ⦿⦿⦿   name · sync chip                    sidebar toggle  ║    from the window's top edge
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
///
/// Which surface gets which treatment is not a style choice — see ``GlassUI/ChromeVibrancy``.
/// Edge bands take a **material** (`NSVisualEffectView`), because they border the desktop and a
/// lens over the desktop is a window. Floating surfaces take **glass**, because the grid is behind
/// them and a lens needs something to refract. The grid takes neither.
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
/// **Exactly three things float**: the selection stats pill, the refresh pill / diff panel, and
/// the ⌘K palette. The first two live in the grid's bottom corners, over the reserved bottom
/// inset, so they never cover a cell that cannot be scrolled out from under them.
struct DocumentWindow: View {
    @Bindable var model: DocumentModel
    let app: AppModel
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [SnapshotRecord] = []
    @State private var isPresentingSaveAs = false
    @State private var paletteState = CommandPaletteState()
    @State private var paletteCommands: [String: PaletteCommand] = [:]
    /// The measured height of the anchored chrome, handed to the grid as a scroll inset so the
    /// two can never disagree about where row 1 begins.
    @State private var chromeHeight: CGFloat = 0
    /// Where the traffic lights are, measured. See ``TitleBarMetrics``.
    @State private var titleBarMetrics: TitleBarMetrics = .unmeasured

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    var body: some View {
        Group {
            if let empty = emptyState {
                VStack(spacing: 0) {
                    TitleBarRow(model: model, context: context, metrics: titleBarMetrics)
                    EmptyStateView(model: empty, context: context) { action in
                        handle(empty, action)
                    }
                }
                .gridPlane(context)
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
        .frame(minWidth: DS.Metrics.minimumWindowWidth, minHeight: DS.Metrics.minimumWindowHeight)
        .glassAppearance(context)
        .overlay { palette }
        .overlay(alignment: .top) { stalenessNote }
        .background(WindowConfigurator())
        .focusedSceneValue(\.document, model)
        .navigationTitle(model.url.lastPathComponent)
        .onAppear { app.refreshMCPStatus() }
        .onDisappear { app.closeDocument(model) }
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

    /// The titlebar, the toolbar and the formula bar, as **one** anchored band on **one** material.
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
    /// So the band is now a single ``GlassUI/ChromeVibrancy/band`` surface that spans the full
    /// window width and runs from the very top of the window to the bottom of the formula bar.
    /// The per-control glass capsules in `ToolbarSurface` sit *on* it; they were never a
    /// substitute for it.
    ///
    /// # Measured, not sized
    ///
    /// The grid insets its scroll range by this band's height, so hardcoding one would show up as
    /// row 1 sitting half under the formula bar. It is measured, and now that the titlebar is part
    /// of the same stack the measurement covers it too — which is what let two eyeballed `120`
    /// and `132` offsets elsewhere in this file become `chromeHeight` plus a token.
    private var chrome: some View {
        VStack(spacing: 0) {
            TitleBarRow(model: model, context: context, metrics: titleBarMetrics)
                .background(TitleBarMetricsReader { titleBarMetrics = $0 })

            ToolbarSurface(state: model.toolbar, context: context) { action in
                perform(action)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Vertical rhythm of its own. Without it the toolbar's capsules touch the titlebar
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
            }
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
                Color.black.opacity(0.18)
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
            .frame(maxWidth: 520)
            .glassCard(context: context, radius: DS.Radius.panel)
            // Was an eyeballed 132 — 12 more than the palette's 120, which is what compensating
            // for an unmeasured chrome height looks like. Same measurement, tighter air, because
            // this note is anchored *to* the formula bar rather than floating below it.
            .padding(.top, chromeHeight + DS.Space.s)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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
            if model.syncState == .missing { isPresentingSaveAs = true }
            else { NSWorkspace.shared.activateFileViewerSelecting([model.url]) }
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
            canSave: model.syncState.allowsSaving && model.hasUnsavedEdits
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
        }
    }

    private func selectDefinedName(_ name: String) {
        guard let defined = model.workbook.definedName(name) ?? model.workbook.definedNames[name],
              let target = defined.target
        else { return }
        if let sheet = target.sheet { model.activeSheetID = sheet }
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
    private func perform(_ action: FormulaBarAction) {
        switch action {
        case .beginEditing:
            model.beginFormulaBarEdit()
        case let .textChanged(text):
            model.formulaBarTextChanged(text)
        case let .commit(text, advance):
            model.commitFormulaBarEdit(text, advance: direction(advance))
            // The caret goes back to the grid, so the arrow keys that follow a commit move the
            // selection instead of moving through a formula that is no longer being edited.
            model.grid.focus()
        case .cancel:
            model.cancelFormulaBarEdit()
            model.grid.focus()
        case let .navigate(text), let .selectDefinedName(text):
            if let ref = CellRef(a1: text.uppercased()) {
                model.selection.select(ref)
                model.grid.scroll(to: ref)
            } else {
                selectDefinedName(text)
            }
        case .insertFunction, .toggleExpanded:
            break
        }
    }

    private func direction(_ advance: FormulaBarAdvance) -> AdvanceDirection? {
        switch advance {
        case .down: .down
        case .up: .up
        case .forward: .forward
        case .backward: .backward
        case .stay: nil
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

// MARK: - Titlebar

/// The window's own top row: traffic lights, document name, live sync chip, sidebar toggle.
///
/// Anchored like everything else, and inset on the leading edge so nothing lands under the close
/// button. The window is `fullSizeContentView` with a transparent titlebar (A5's
/// ``GlassUI/WindowChrome``), which is what lets the document plane run to the very top of the
/// window instead of stopping at a hard seam.
/// The window's title row — **on the traffic-light line**, not below it.
///
/// # Why it is not its own band
///
/// It used to be a 38pt row underneath the titlebar, which left the traffic lights sitting alone
/// on an otherwise empty strip. That is two rows of chrome doing one row of work, and in an app
/// whose entire job is showing as many spreadsheet rows as possible it is the most expensive kind
/// of whitespace. Finder, Xcode, Safari and Notes all put real controls inline beside the lights;
/// this now does the same, and the grid gets the height back.
///
/// # The two things that make it work
///
/// **The leading inset is measured.** ``TitleBarMetrics`` reads the zoom button's frame, so the
/// content clears the real buttons wherever the system puts them, and collapses to a plain margin
/// in full screen when they are gone.
///
/// **The empty stretches still drag the window.** Everything here is either a control or a
/// `Spacer`, and the row draws no background of its own — the band behind it does. The metrics
/// reader returns `nil` from `hitTest`, and `Spacer`/`Text` are not hit-testable, so a click on
/// the empty middle falls through to AppKit's titlebar and drags. Only the buttons and the chip
/// take the click.
private struct TitleBarRow: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext
    let metrics: TitleBarMetrics

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Color.clear.frame(width: metrics.leadingInset, height: DS.Stroke.hairline(context))

            Button {
                model.isSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show or hide the sidebar")
            .accessibilityLabel("Toggle sidebar")

            Text(model.url.lastPathComponent)
                .font(DS.Text.controlEmphasis)
                .foregroundStyle(DS.Chrome.primary)
                .lineLimit(1)
                // The name yields first when the window narrows. The alternative — a fixed name
                // and a compressed chip — turns "3 unsaved" into an ellipsis, and the chip is the
                // half that is telling you something you did not already know.
                .truncationMode(.middle)
                .layoutPriority(-1)
            if model.hasUnsavedEdits {
                Circle()
                    .fill(DS.Chrome.secondary)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }

            Spacer(minLength: DS.Space.s)

            SyncStateChip(state: chipState, context: context) {
                switch model.syncState {
                case .stale: Task { await model.refresh() }
                case .conflict: model.showDiffPanel()
                case .dirty: Task { await model.save() }
                default: Task { await model.setAutoRefresh(!model.isWatching) }
                }
            }

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show or hide the inspector")
            .accessibilityLabel("Toggle inspector")
        }
        .padding(.trailing, DS.Space.m)
        // Twice the measured centre line, so the row's own centre lands exactly on the buttons'.
        .frame(height: metrics.centreFromTop * 2)
        .accessibilityElement(children: .contain)
    }

    private var chipState: GlassUI.SyncState {
        SyncPresentation.chip(
            for: model.syncState,
            pendingCellCount: model.changeSet?.notice.cellCount ?? 0,
            localEditCount: model.localEditCount,
            isWatching: model.isWatching,
            readOnlyReason: model.workbook.meta.readOnlyReason
        )
    }
}
