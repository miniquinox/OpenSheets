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
/// ┌───────────────────────────────────────────────────────────┐
/// │ titlebar        name · sync chip            sidebar toggle │  anchored, traffic-light inset
/// ├───────────────────────────────────────────────────────────┤
/// │ toolbar                                                    │  anchored — the grid runs under it
/// ├───────────────────────────────────────────────────────────┤
/// │ formula bar                                                │  anchored — and under this too
/// ├──────────────┬────────────────────────────────────────────┤
/// │ sidebar      │ grid              ·stats pill  ·sync pill   │  siblings; only the two pills float
/// ├──────────────┴────────────────────────────────────────────┤
/// │ sheet tabs                                                 │  anchored, full window width
/// └───────────────────────────────────────────────────────────┘
/// ```
///
/// The toolbar spans the whole window, above the split, so the sidebar cannot clip its leading
/// controls no matter how wide it gets. The grid is the one opaque plane and carries
/// ``SwiftUI/View/gridPlane(_:)``, so the chrome's lens sits on the document rather than on a
/// window background of its own.
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
/// behaves. The sidebar and the inspector stay below the chrome rather than under it: they are
/// glass themselves, and glass on glass is two lenses stacked, which §3.2 forbids.
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

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            TitleBarRow(model: model, context: context)
            if let empty = emptyState {
                EmptyStateView(model: empty, context: context) { action in
                    handle(empty, action)
                }
                .gridPlane(context)
            } else {
                ZStack(alignment: .top) {
                    split
                    chrome
                }
                SheetTabPlate(model: model, context: context)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background(GridTheme.resolved(context).canvas.color)
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

    /// The toolbar and the formula bar, as one anchored band.
    ///
    /// Measured rather than sized: the grid needs the exact height to inset by, and hardcoding it
    /// would drift the moment a control size or a font changed — which shows up as row 1 sitting
    /// half under the formula bar, the most obviously broken thing a spreadsheet can do.
    private var chrome: some View {
        VStack(spacing: 0) {
            ToolbarSurface(state: model.toolbar, context: context) { action in
                perform(action)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) { hairline }

            FormulaBar(state: model.formulaBar, context: context) { action in
                perform(action)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.bottom, DS.Space.s)
            .background(alignment: .bottom) { hairline }
        }
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

    private var split: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarColumn(model: model, app: app, context: context)
                    .padding(.top, chromeHeight)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle()
                    .fill(DS.Chrome.separator(context))
                    .frame(width: DS.Stroke.hairline(context))
                    .padding(.top, chromeHeight)
            }
            // The only column that runs the full height, up behind the chrome. Its scroll insets
            // give the band back, so nothing is hidden — see `GridPane`.
            GridPane(model: model, context: context, chromeInset: chromeHeight)
            if model.isInspectorVisible {
                Rectangle()
                    .fill(DS.Chrome.separator(context))
                    .frame(width: DS.Stroke.hairline(context))
                    .padding(.top, chromeHeight)
                InspectorColumn(model: model, context: context)
                    .padding(.top, chromeHeight)
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
                .padding(.top, 120)
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
                VStack(alignment: .leading, spacing: 2) {
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
            .padding(.top, 132)
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

    private func perform(_ action: FormulaBarAction) {
        switch action {
        case .beginEditing:
            model.grid.beginEdit()
        case let .commit(text):
            _ = model.commitEdit(at: model.selection.active, text: text, advance: .down)
        case .cancel:
            model.grid.cancelEdit()
        case let .navigate(text), let .selectDefinedName(text):
            if let ref = CellRef(a1: text.uppercased()) {
                model.selection.select(ref)
                model.grid.scroll(to: ref)
            } else {
                selectDefinedName(text)
            }
        case .textChanged, .insertFunction, .toggleExpanded:
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

// MARK: - Titlebar

/// The window's own top row: traffic lights, document name, live sync chip, sidebar toggle.
///
/// Anchored like everything else, and inset on the leading edge so nothing lands under the close
/// button. The window is `fullSizeContentView` with a transparent titlebar (A5's
/// ``GlassUI/WindowChrome``), which is what lets the document plane run to the very top of the
/// window instead of stopping at a hard seam.
private struct TitleBarRow: View {
    @Bindable var model: DocumentModel
    let context: AppearanceContext

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Color.clear.frame(width: 72, height: 1)

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
            if model.hasUnsavedEdits {
                Circle()
                    .fill(DS.Chrome.secondary)
                    .frame(width: 5, height: 5)
                    .accessibilityLabel("Unsaved changes")
            }

            Spacer(minLength: DS.Space.l)

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
        .padding(.horizontal, DS.Space.m)
        .frame(height: 38)
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
