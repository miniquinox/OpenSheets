#if canImport(AppKit)
import AppKit
#endif
import Foundation
import GlassUI
import GridKit
import Observation
import SheetFormat
import SheetFormula
import SheetModel
import SheetStore

/// One open document.
///
/// # Per document, never a singleton
///
/// The house `@Observable` store pattern is a singleton. That is wrong for a document app and it
/// bites at the second window, not the first: two workbooks share one selection, one undo stack
/// and one sync state, and every symptom points somewhere else. So this is created per document,
/// held by the scene, and released when the window closes — which is asserted by
/// `DocumentCoreTests.closingADocumentDeallocatesIt`, because "no leaks" is a claim that decays
/// the moment nobody checks it.
///
/// # Who owns the workbook
///
/// This does, for rendering and editing. ``DocumentSession`` owns it for *I/O* — it is what gets
/// written on ⌘S — and the two are reconciled at exactly two points: ``markEdited()`` tells the
/// session that memory has moved on without shipping it a copy, and ``pushWorkbookToSession()``
/// hands the real value over immediately before any save. That split is not fussiness. `Workbook`
/// is copy-on-write, so handing the actor a copy on every keystroke makes the *next* keystroke
/// deep-copy the edited sheet's `CellStore` — tens of megabytes per character on a large sheet.
/// One copy per save is free; one per keystroke is the difference between a spreadsheet and a
/// slideshow.
///
/// # Effects, not decisions
///
/// Addendum §10: `DocumentSyncState.transition(on:context:)` names the I/O to perform and
/// ``DocumentSession`` performs it. Nothing here decides when to snapshot, when to reload or
/// whether a conflict is a conflict. This listens to ``DocumentSessionEvent`` and renders it.
@MainActor
@Observable
public final class DocumentModel {
    // MARK: - Identity

    public nonisolated let url: URL
    /// The folder that was granted when this file was opened. PLAN.md §7.2.
    public nonisolated let workspaceURL: URL

    // MARK: - Document state

    public private(set) var workbook: Workbook
    public var activeSheetID: SheetID {
        didSet { if activeSheetID != oldValue { selection = GridSelection() } }
    }

    public var selection = GridSelection() {
        didSet { if selection != oldValue { refreshSelectionDerived() } }
    }

    public private(set) var syncState: DocumentSyncState = .synced
    public private(set) var isWatching = true
    public private(set) var lastError: SheetError?
    /// Set when the file's path is gone and the in-memory workbook is the only copy.
    public private(set) var needsSaveAs = false

    // MARK: - The sync surface

    public private(set) var syncPhase: SyncSurface.Phase = .hidden
    public private(set) var changeSet: FileChangeSet?
    public var diffSheetFilter: String?
    /// Per-sheet counts for the tab dots and the sidebar badges.
    public private(set) var pendingChangesBySheet: [SheetID: Int] = [:]
    public private(set) var feed: [SessionFeedEntry] = []
    /// Shown once per session, the first time an edit lands on a workbook whose charts or pivots
    /// will not follow it. Addendum §5.
    public private(set) var stalenessWarning: StalenessNotice?

    // MARK: - Derived UI state

    public private(set) var selectionStats: SelectionStats
    public private(set) var formulaBar = FormulaBarState()
    public private(set) var toolbar = ToolbarState()
    /// The undo stack's public face, so the menu can be built without reaching into it.
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var undoName: String?
    public private(set) var redoName: String?

    public var zoom: Double = 1
    public var showsFormulas = false
    public var isSidebarVisible = true
    public var isInspectorVisible = false
    public var isPaletteVisible = false
    /// `File ▸ Restore snapshot…` — PLAN.md §1.2 step 8, the way out when the agent got it wrong.
    /// On the model rather than in the window's `@State` so the menu bar can reach it.
    public var isPresentingSnapshots = false

    /// The imperative handle on the grid — flash, scroll, begin edit.
    public let grid = GridController()

    // MARK: - Machinery

    @ObservationIgnored private let session: DocumentSession
    @ObservationIgnored private let reader: DocumentWorkbookReader
    @ObservationIgnored private let writer: DocumentWorkbookWriter?
    @ObservationIgnored private var engine: FormulaEngine
    @ObservationIgnored private var edits = WorkbookEditTracker()
    @ObservationIgnored private var undoStack = DocumentUndoStack()
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var pendingDiff: WorkbookDiff?
    @ObservationIgnored private let timestampFormatter: DateFormatter
    @ObservationIgnored private var feedCounter = 0

    // MARK: - Life cycle

    public init(
        url: URL,
        workspaceURL: URL,
        workbook: Workbook,
        session: DocumentSession,
        reader: DocumentWorkbookReader,
        writer: DocumentWorkbookWriter?,
        autoRefresh: Bool = true
    ) {
        self.url = url
        self.workspaceURL = workspaceURL
        self.workbook = workbook
        self.session = session
        self.reader = reader
        self.writer = writer
        engine = FormulaEngine(workbook: workbook)
        activeSheetID = workbook.visibleSheets.first?.id ?? workbook.sheets.first?.id ?? SheetID(1)
        isWatching = autoRefresh
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        timestampFormatter = formatter
        selectionStats = SelectionStats(rangeLabel: "A1", values: [:])
        refreshSelectionDerived()
        startPump()
        scheduleOpenRecalculation()
    }

    /// Stops the watcher and releases the session.
    ///
    /// Called from the window's `onDisappear`. `deinit` also does it, so a window torn down
    /// without ceremony still stops watching — but a document that only stops watching when ARC
    /// gets round to it is a document that keeps a file descriptor open for an unbounded time,
    /// and that is exactly the class of bug that shows up as "the app stopped noticing my file"
    /// after the twentieth window.
    public func close() {
        pump?.cancel()
        pump = nil
        let session = session
        let reader = reader
        let writer = writer
        let url = url
        Task.detached {
            await session.stop()
            await MainActor.run {
                reader.forget(url)
                writer?.clearStage(for: url)
            }
        }
    }

    isolated deinit {
        pump?.cancel()
        let session = session
        Task.detached { await session.stop() }
    }

    private func startPump() {
        // `[weak self]` is what makes the acceptance criterion reachable: the stream is owned by
        // the session, so a strong capture here would keep the model alive for as long as the
        // watcher runs — which is forever.
        pump = Task { [weak self] in
            guard let events = self?.session.events else { return }
            for await event in events {
                guard let self else { return }
                await handle(event)
            }
        }
    }

    // MARK: - Session events

    private func handle(_ event: DocumentSessionEvent) async {
        switch event {
        case let .stateChanged(_, to):
            syncState = to
            if to == .synced { clearPendingChanges() }
        case let .refreshed(diff):
            await applyRefresh(diff)
        case .saved:
            edits.reset()
            writer?.clearStage(for: url)
            lastError = nil
        case let .diffAvailable(diff):
            present(diff)
        case let .failed(error):
            lastError = error
        case .saveAsRequired:
            needsSaveAs = true
        }
    }

    /// PLAN.md §1.2 step 7: the grid reloads, the changed cells flash, and the sidebar keeps the
    /// record.
    private func applyRefresh(_ diff: WorkbookDiff) async {
        let fresh = await session.workbook
        workbook = fresh
        workbookGeneration &+= 1
        if workbook[activeSheetID] == nil {
            activeSheetID = workbook.visibleSheets.first?.id ?? workbook.sheets.first?.id ?? SheetID(1)
        }
        engine = FormulaEngine(workbook: workbook)
        edits.reset()
        writer?.clearStage(for: url)

        // The on-disk file is the source of truth after an external change, so an undo step
        // recorded against the version we just replaced would put back cells that no longer mean
        // anything. The diff panel says so, quietly, once — see `refreshClearedUndo`.
        let hadUndo = undoStack.canUndo
        undoStack.clear()
        refreshUndoState()
        refreshClearedUndo = hadUndo

        pendingDiff = nil
        changeSet = nil
        syncPhase = .hidden
        clearPendingChanges()
        refreshSelectionDerived()
        // A refresh is a re-open: the agent that just wrote this file is exactly the kind of tool
        // that writes formulas without computing them, so the cache is no more trustworthy now
        // than it was on open — and `workbook` has just been replaced by what is on disk, which
        // is true whether or not the diff had anything in it.
        scheduleOpenRecalculation()

        guard !diff.isEmpty else { return }
        feedCounter += 1
        var entry = SyncPresentation.feedEntry(
            for: diff, at: Date(), id: "refresh-\(feedCounter)", formatter: timestampFormatter
        )
        // Said once, quietly, in the one place that survives the refresh. The diff panel would be
        // the obvious home for it, but the panel is gone by the time it is true — the whole point
        // is that the file on disk has just become the source of truth.
        if hadUndo { entry.summary += " · undo history cleared" }
        feed.insert(entry, at: 0)
        if feed.count > 50 { feed.removeLast(feed.count - 50) }

        // A style-only difference must not flash: the point of the flash is "the agent changed
        // this number", and a reformat is not that.
        if let refs = diff.flashSets[activeSheetID], !refs.isEmpty {
            grid.flash(refs)
        }
    }

    /// A change is on disk and has not been applied. `STALE`, or `CONFLICT`.
    private func present(_ diff: WorkbookDiff) {
        let wasOpen = syncPhase == .panel
        let isRediff = pendingDiff != nil && pendingDiff != diff
        pendingDiff = diff
        changeSet = SyncPresentation.changeSet(
            for: diff,
            workbook: workbook,
            state: syncState,
            localEditCount: undoStack.depthUsed,
            isWatching: isWatching,
            wasRediffed: wasOpen && isRediff
        )
        pendingChangesBySheet = Dictionary(
            uniqueKeysWithValues: diff.sheetDiffs.map { ($0.sheetID, $0.totalCellChangeCount) }
        )
        syncPhase = wasOpen ? .panel : .pill
    }

    private func clearPendingChanges() {
        pendingChangesBySheet = [:]
    }

    /// Unsaved actions, for the conflict banner's "you have 3 unsaved edits".
    public var localEditCount: Int { undoStack.depthUsed }

    /// Grow the pill into the panel. PLAN.md §1.2 step 6.
    public func showDiffPanel() {
        guard changeSet != nil else { return }
        syncPhase = .panel
    }

    /// Shrink the panel back to the pill.
    public func collapseSyncSurface() {
        guard changeSet != nil else { return }
        syncPhase = .pill
    }

    /// Dismiss without deciding. The pill comes back on the next change.
    public func dismissSyncSurface() {
        syncPhase = .hidden
    }

    /// Everything the pill and the panel can ask for, routed.
    ///
    /// One switch, because the pill and the panel are two shapes of one surface and the actions
    /// they emit are one flow. `discardFileChanges` is the only one that needs explaining: there
    /// are no local edits in that state, so "discard what is on disk" means writing memory back
    /// over the file — which is a save, and is exactly `keepMine` without the conflict.
    public func handle(_ action: SyncAction) async {
        switch action {
        case .expand:
            showDiffPanel()
        case .collapse:
            collapseSyncSurface()
        case .refresh:
            await refresh()
        case let .showInGrid(id):
            showInGrid(id)
        case .discardFileChanges:
            _ = await save()
            dismissSyncSurface()
        case .keepMine:
            await resolveConflict(.keepMine)
        case .takeDisk:
            await resolveConflict(.takeDisk)
        case let .filterSheet(name):
            diffSheetFilter = name
        case .dismiss:
            dismissSyncSurface()
        }
    }

    /// PLAN.md §1.2 step 6's `Show in grid`. Does not close the panel.
    private func showInGrid(_ changeID: String) {
        guard let change = changeSet?.changes.first(where: { $0.id == changeID }) else { return }
        if let sheet = workbook.sheets.first(where: { $0.name == change.sheetName }) {
            activeSheetID = sheet.id
        }
        selection.select(change.ref)
        grid.scroll(to: change.ref)
        grid.flash([change.ref])
    }

    /// A statistic was chosen from the stats pill's context menu.
    public func setSelectionStats(_ visible: [SelectionStat]) {
        selectionStats = SelectionStats(
            rangeLabel: selectionStats.rangeLabel,
            values: selectionStats.values,
            visible: visible
        )
    }

    /// The floating stats pill was clicked.
    public func cycleSelectionStats() {
        selectionStats = SelectionStats(
            rangeLabel: selectionStats.rangeLabel,
            values: selectionStats.values,
            visible: SelectionStats.cycled(selectionStats.visible)
        )
    }

    /// Everything the grid asks the shell to do (A4's ``GridKit/GridEvent``).
    ///
    /// The grid never mutates a workbook — it draws one and emits these. Routing them all through
    /// one function is what puts every change through the same undo, recalculation and dirty-part
    /// path instead of three parallel ones that drift.
    public func handle(_ event: GridEvent) {
        switch event {
        case let .selectionChanged(updated):
            selection = updated
        case let .beginEdit(ref, seed):
            _ = (ref, seed)
        case let .commitEdit(ref, text, advance):
            _ = commitEdit(at: ref, text: text, advance: advance)
        case .cancelEdit:
            formulaBar.diagnostic = nil
        case let .clearContents(ranges):
            clearContents(in: ranges)
        case let .fillHandleDragged(source, target):
            fill(from: source, to: target)
        case let .columnsResized(columns, width):
            resizeColumns(columns, to: width)
        case let .rowsResized(rows, height):
            resizeRows(rows, to: height)
        case let .autoFitColumns(_, suggested):
            for (column, width) in suggested { resizeColumns(column ... column, to: width) }
        case let .autoFitRows(_, suggested):
            for (row, height) in suggested { resizeRows(row ... row, to: height) }
        case let .activateHyperlink(ref, link):
            pendingHyperlink = (ref, link)
        case let .zoomChanged(value):
            zoom = value
        case .contextMenu, .visibleRangeChanged, .doubleClicked:
            break
        }
    }

    /// A hyperlink the user clicked. **Nothing is fetched** — PLAN.md §7.3 requires the resolved
    /// URL be shown before anything goes anywhere, so this is a request for confirmation, not an
    /// action. The window presents it; clearing it is the answer.
    public var pendingHyperlink: (ref: CellRef, link: Hyperlink)?

    public func clearPendingHyperlink() { pendingHyperlink = nil }

    /// Set for one refresh, so the diff panel can say the undo stack went with it.
    public private(set) var refreshClearedUndo = false

    // MARK: - The three verbs

    /// ⌘R.
    public func refresh() async {
        // Parse off the main actor and off the session's executor, then hand the session a
        // result it can use without blocking anything. See `DocumentWorkbookReader`.
        if let fresh = try? await DocumentWorkbookReader.read(url) {
            reader.prime(fresh, for: url)
        }
        enqueue { await $0.refresh() }
        await drainSessionQueue()
    }

    /// ⌘S.
    @discardableResult
    public func save() async -> Bool {
        guard syncState.allowsSaving else { return false }
        writer?.stage(edits, for: url)
        pushWorkbookToSession()
        enqueue { await $0.save() }
        await drainSessionQueue()
        return await session.state == .synced
    }

    /// File ▸ Save As…
    public func saveAs(to destination: URL) async throws(SheetError) {
        writer?.stage(edits, for: url)
        writer?.stage(edits, for: destination)
        pushWorkbookToSession()
        await drainSessionQueue()
        _ = try await session.saveAs(to: destination)
        edits.reset()
        needsSaveAs = false
    }

    /// One of the conflict banner's three buttons.
    ///
    /// `keepMine` saves over the file, `takeDisk` throws the local edits away and reloads,
    /// `compare` opens the diff and resolves nothing. The state machine does the deciding; all
    /// this does is make sure the workbook the session is about to write is the one on screen.
    public func resolveConflict(_ resolution: ConflictResolution) async {
        switch resolution {
        case .keepMine:
            writer?.stage(edits, for: url)
            pushWorkbookToSession()
        case .takeDisk:
            if let fresh = try? await DocumentWorkbookReader.read(url) {
                reader.prime(fresh, for: url)
            }
        case .compare:
            syncPhase = .panel
        }
        enqueue { await $0.resolveConflict(resolution) }
        await drainSessionQueue()
    }

    /// Pause or resume the watcher's effect. The watcher keeps running; auto-refresh is what
    /// stops, so a paused document still knows the file changed and still offers ⌘R.
    public func setAutoRefresh(_ enabled: Bool) async {
        isWatching = enabled
        await session.setAutoRefresh(enabled)
    }

    /// Snapshots of this file, newest first.
    public func snapshots() async -> [SnapshotRecord] {
        (try? await session.snapshotHistory()) ?? []
    }

    /// File ▸ Restore snapshot…
    public func restore(_ id: ULID) async {
        do {
            reader.forget(url)
            _ = try await session.restore(id)
        } catch {
            lastError = error
        }
    }

    /// Hands the session the workbook it is about to write.
    private func pushWorkbookToSession() {
        let snapshot = workbook
        enqueue { await $0.replaceWorkbook(snapshot) }
    }

    /// Tells the session that memory has moved on, without shipping it a copy.
    ///
    /// `DocumentSession.edit` takes a non-`Sendable` `(inout Workbook) -> T`, so a closure that
    /// captured anything could not cross the actor boundary at all. This one captures nothing and
    /// is declared `@Sendable`, which is what makes it legal to send — and it is deliberately a
    /// no-op: the point is the `.userEdited` event the session raises, not the closure.
    private nonisolated static let noopEdit: @Sendable (inout Workbook) -> Void = { _ in }

    private func markEdited() {
        // Memory has moved on, so any background pass started against the old value is void.
        workbookGeneration &+= 1
        enqueue { await $0.edit(DocumentModel.noopEdit) }
    }

    /// Everything this model asks of the session, in order.
    ///
    /// Unstructured `Task`s would not be. A `markEdited()` that landed *after* a `saveSucceeded`
    /// would put the document back into `DIRTY` with nothing to save — a permanently dirty
    /// document that ⌘S cannot clean, arrived at by a race that reproduces once a week.
    private func enqueue(_ operation: @escaping @Sendable (DocumentSession) async -> Void) {
        let session = session
        let previous = sessionQueue
        sessionQueue = Task { @MainActor in
            await previous?.value
            await operation(session)
        }
    }

    /// Waits for everything queued so far. Verbs that need an answer call it.
    private func drainSessionQueue() async {
        await sessionQueue?.value
    }

    @ObservationIgnored private var sessionQueue: Task<Void, Never>?

    // MARK: - Editing

    /// Commits a cell editor or the formula bar.
    ///
    /// The whole editing path in one place, in PLAN.md §8's order: parse → refuse a formula that
    /// does not compile → write → recalculate dependents → apply → mark the parts dirty.
    @discardableResult
    public func commitEdit(at ref: CellRef, text: String, advance: AdvanceDirection? = nil) -> Bool {
        guard isEditable else { return false }
        guard let sheet = workbook[activeSheetID] else { return false }

        let styleID = sheet.cells[ref]?.styleID ?? sheet.effectiveStyleID(at: ref)
        let format = workbook.styles.numberFormat(for: styleID)
        let parsed = CellInputParser.parse(
            text, format: format, dateSystem: workbook.meta.dateSystem
        )

        var cell = sheet.cells[ref] ?? Cell(value: .empty, styleID: styleID)
        cell.styleID = styleID
        cell.flags.remove(.staleCache)

        let target = SheetCell(sheet: activeSheetID, ref: ref)
        if let source = parsed.formula {
            // PLAN.md §8: a formula parses before it is committed. Refusing here is what stops a
            // syntax error becoming a cell that reads `#NAME?` forever.
            guard engine.setFormula(source, at: target, in: workbook) else {
                formulaBar.diagnostic = "That formula does not parse."
                return false
            }
            cell.formula = source
            cell.value = .empty
        } else {
            if cell.isFormula { engine.setFormula(nil, at: target, in: workbook) }
            cell.formula = nil
            cell.value = parsed.value
            if text.count > Limits.maxCellTextLength {
                formulaBar.diagnostic = "A cell holds at most \(Limits.maxCellTextLength.formatted()) characters."
                return false
            }
        }

        var styles = workbook.styles
        if let formatID = parsed.suggestedNumberFormatID {
            cell.styleID = styles.derive(cell.styleID) { $0.numberFormatID = formatID }
        }

        let selectionBefore = selection
        var selectionAfter = selection
        if let advance, let advanced = selection.advancingActive(advance) {
            selectionAfter = advanced
        }

        let stylesBefore = workbook.styles
        workbook.styles = styles
        guard var edit = WorkbookEditor.setCells(
            [ref: cell],
            on: activeSheetID,
            in: &workbook,
            selectionBefore: selectionBefore,
            selectionAfter: selectionAfter,
            name: "Typing",
            coalescingKey: "type:\(activeSheetID.rawValue):\(ref.a1String)",
            formulasChanged: parsed.formula != nil || sheet.cells[ref]?.isFormula == true
        ) else {
            workbook.styles = stylesBefore
            selection = selectionAfter
            return true
        }
        if stylesBefore != styles {
            edit.styles = (stylesBefore, styles)
            edit.stylesChanged = true
        }

        formulaBar.diagnostic = nil
        recalculate(changed: [target])
        commit(edit)
        return true
    }

    /// Delete / Backspace. `ranges` defaults to the selection; the grid passes its own, which is
    /// the same thing today and would not be if a future gesture cleared something narrower.
    public func clearContents(in ranges: [CellRange]? = nil) {
        guard isEditable else { return }
        let target = ranges?.isEmpty == false ? ranges! : selection.ranges
        guard let edit = WorkbookEditor.clearContents(
            in: target, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        recalculate(changed: changedCells(in: edit))
        commit(edit)
    }

    public func paste(_ mode: WorkbookEditor.PasteMode = .everything) {
        guard isEditable else { return }
        #if canImport(AppKit)
        guard let payload = Clipboard.read(
            at: selection.active, dateSystem: workbook.meta.dateSystem
        ) else { return }
        guard let edit = WorkbookEditor.paste(
            payload,
            at: selection.activeRange,
            mode: mode,
            on: activeSheetID,
            in: &workbook,
            selection: selection
        ) else { return }
        recalculate(changed: changedCells(in: edit))
        commit(edit)
        #endif
    }

    public func copy(cut: Bool = false) {
        #if canImport(AppKit)
        guard let sheet = workbook[activeSheetID] else { return }
        let range = selection.boundingRange
        let payload = ClipboardPayload.capture(
            range, from: sheet, styles: workbook.styles, wasCut: cut
        )
        let formatter = CellFormatter(
            styles: workbook.styles, dateSystem: workbook.meta.dateSystem, theme: .light
        )
        let text = payload.tabSeparatedText { cell in
            guard let cell else { return "" }
            // A cut or copy of a formula puts the *formula* on the text pasteboard, because that
            // is what a person pasting into a terminal or another spreadsheet means by copying it.
            if let formula = cell.formula { return "=" + formula }
            return formatter.display(of: cell, styleID: cell.styleID).text
        }
        Clipboard.write(payload, text: text)
        if cut { clearContents() }
        refreshToolbar()
        #endif
    }

    public func fill(from source: CellRange, to target: CellRange) {
        guard isEditable else { return }
        guard let edit = WorkbookEditor.fill(
            from: source, to: target, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        recalculate(changed: changedCells(in: edit))
        commit(edit)
    }

    /// Insert or delete rows and columns, with A3's reference algebra applied to every formula.
    public func structural(_ kind: StructuralEdit.Kind) {
        guard isEditable else { return }
        let range = selection.boundingRange
        let edit: StructuralEdit
        switch kind {
        case .insertRows: edit = .insertRows(at: range.start.row, count: range.rowCount, on: activeSheetID)
        case .deleteRows: edit = .deleteRows(at: range.start.row, count: range.rowCount, on: activeSheetID)
        case .insertColumns:
            edit = .insertColumns(at: range.start.column, count: range.columnCount, on: activeSheetID)
        case .deleteColumns:
            edit = .deleteColumns(at: range.start.column, count: range.columnCount, on: activeSheetID)
        }
        do {
            guard let recorded = try WorkbookEditor.structural(
                edit, in: &workbook, selection: selection
            ) else { return }
            engine.rebuild(from: workbook)
            let result = engine.recalculateAll(in: workbook)
            result.apply(to: &workbook)
            commit(recorded, staleness: stalenessSource.forStructuralEdit())
        } catch {
            lastError = error
        }
    }

    public func sort(ascending: Bool) {
        guard isEditable else { return }
        let range = selection.boundingRange
        guard let edit = WorkbookEditor.sort(
            range,
            by: selection.active.column,
            ascending: ascending,
            hasHeaderRow: false,
            on: activeSheetID,
            in: &workbook,
            selection: selection
        ) else { return }
        recalculate(changed: changedCells(in: edit))
        commit(edit)
    }

    public func restyle(_ name: String, _ transform: (inout CellStyle) -> Void) {
        guard isEditable else { return }
        guard let edit = WorkbookEditor.restyle(
            selection.ranges,
            on: activeSheetID,
            in: &workbook,
            selection: selection,
            name: name,
            transform: transform
        ) else { return }
        commit(edit)
    }

    public func resizeColumns(_ columns: ClosedRange<Int>, to width: Double) {
        guard isEditable else { return }
        guard let edit = WorkbookEditor.resizeColumns(
            columns, to: width, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        commit(edit)
    }

    public func resizeRows(_ rows: ClosedRange<Int>, to height: Double) {
        guard isEditable else { return }
        guard let edit = WorkbookEditor.resizeRows(
            rows, to: height, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        commit(edit)
    }

    public func toggleMerge() {
        guard isEditable else { return }
        guard let edit = WorkbookEditor.toggleMerge(
            selection.boundingRange, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        commit(edit)
    }

    /// Adds or removes a decimal place across the selection.
    ///
    /// Works on the resolved format code rather than on a preset, because a cell that reads
    /// `$#,##0.00` must become `$#,##0.000` and not "Number with three decimals" — the currency
    /// symbol and the grouping are the user's, and a preset would quietly take them away.
    public func adjustDecimals(by delta: Int) {
        guard isEditable, let sheet = workbook[activeSheetID] else { return }
        var styles = workbook.styles
        let stylesBefore = styles
        var values: [CellRef: Cell?] = [:]

        for range in selection.ranges {
            for ref in range {
                let current = sheet.cells[ref]
                let sourceID = current?.styleID ?? sheet.effectiveStyleID(at: ref)
                let format = styles.numberFormat(for: sourceID)
                guard let adjusted = NumberFormatDecimals.adjusting(format, by: delta) else { continue }
                let formatID = styles.internNumberFormat(adjusted)
                let derived = styles.derive(sourceID) { $0.numberFormatID = formatID }
                guard derived != sourceID else { continue }
                var cell = current ?? Cell(value: .empty)
                cell.styleID = derived
                values[ref] = cell
            }
        }
        guard !values.isEmpty else { return }

        workbook.styles = styles
        guard var edit = WorkbookEditor.setCells(
            values,
            on: activeSheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: selection,
            name: delta > 0 ? "Add a decimal place" : "Remove a decimal place"
        ) else {
            workbook.styles = stylesBefore
            return
        }
        edit.styles = (stylesBefore, styles)
        edit.stylesChanged = true
        commit(edit)
    }

    /// Show or hide a sheet. `workbook.xml` metadata, so it marks that part and nothing else.
    public func setSheetVisibility(_ id: SheetID, _ visibility: SheetVisibility) {
        guard isEditable, let before = workbook[id], before.visibility != visibility else { return }
        var after = before
        after.visibility = visibility
        workbook.update(after)
        var edit = DocumentEdit(
            payload: .sheets(before: [before], after: [after]),
            regions: [],
            metadataChanged: true,
            sheetBefore: activeSheetID,
            sheetAfter: visibility == .visible ? id : activeSheetID,
            selectionBefore: selection,
            selectionAfter: selection,
            name: visibility == .visible ? "Show sheet" : "Hide sheet"
        )
        edit.regions = []
        commit(edit)
        if visibility == .visible { activeSheetID = id }
    }

    public func toggleFrozenPanes() {
        guard isEditable, let sheet = workbook[activeSheetID] else { return }
        let panes = sheet.frozen.isFrozen
            ? FrozenPanes.none
            : FrozenPanes(frozenRows: selection.active.row, frozenColumns: selection.active.column)
        guard let edit = WorkbookEditor.setFrozenPanes(
            panes, on: activeSheetID, in: &workbook, selection: selection
        ) else { return }
        commit(edit)
    }

    /// Inserts `=SUM(…)` (or one of its four siblings) below or beside the selection.
    public func autoSum(_ function: AutoSumFunction) {
        guard isEditable, let sheet = workbook[activeSheetID] else { return }
        let range = selection.activeRange
        // The block above the selection, up to the first gap — Excel's rule, and the one that
        // makes the button worth a click rather than a formula worth typing.
        var top = range.start.row
        while top > 0, sheet.cells[CellRef(row: top - 1, column: range.start.column)] != nil {
            top -= 1
        }
        guard top < range.start.row else { return }
        let source = CellRange(
            start: CellRef(row: top, column: range.start.column),
            end: CellRef(row: range.start.row - 1, column: range.start.column)
        )
        _ = commitEdit(
            at: range.start,
            text: "=\(function.label)(\(source.a1String))"
        )
    }

    // MARK: - Undo

    public func undo() {
        guard let edit = undoStack.undo() else { return }
        apply(edit, direction: .undo)
    }

    public func redo() {
        guard let edit = undoStack.redo() else { return }
        apply(edit, direction: .redo)
    }

    private func apply(_ edit: DocumentEdit, direction: DocumentEdit.Direction) {
        edit.apply(direction, to: &workbook)
        activeSheetID = direction == .undo ? edit.sheetBefore : edit.sheetAfter
        selection = direction == .undo ? edit.selectionBefore : edit.selectionAfter
        engine.rebuild(from: workbook)
        note(edit)
        markEdited()
        refreshUndoState()
        refreshSelectionDerived()
    }

    private func commit(_ edit: DocumentEdit, staleness: StalenessNotice? = nil) {
        undoStack.record(edit)
        note(edit)
        markEdited()
        selection = edit.selectionAfter
        refreshUndoState()
        refreshSelectionDerived()

        let notice = staleness ?? stalenessSource.forCellEdit()
        if stalenessWarning == nil, !notice.isEmpty, !hasShownStaleness {
            hasShownStaleness = true
            stalenessWarning = notice
        }
    }

    @ObservationIgnored private var hasShownStaleness = false
    @ObservationIgnored private lazy var stalenessSource = StalenessNotice.detect(in: workbook)

    /// Dismisses the "charts keep their cached values" note.
    public func dismissStalenessWarning() {
        stalenessWarning = nil
    }

    /// Tells the writer what changed — and only what changed.
    ///
    /// Addendum §2 in one function. `regions` comes from the edit itself, so a column resize marks
    /// `<cols>` and a cell edit does not; marking `.all` here would regenerate `<sheetFormatPr>`
    /// from the model and rewrite the file's row height with OpenSheets' 24 pt display default.
    private func note(_ edit: DocumentEdit) {
        // An empty region set means the edit changed nothing *inside* the worksheet part — a
        // sheet rename or a visibility change lives in `workbook.xml`. Marking the sheet anyway
        // would rewrite `sheetN.xml` to say exactly what it already said, and every needless
        // rewrite is a chance to lose something the model does not carry.
        for id in edit.affectedSheets where !edit.regions.isEmpty {
            guard let sheet = workbook[id] else { continue }
            edits.note(sheet, edit.regions)
            if edit.formulasChanged { edits.noteCellsChanged(in: sheet, formulasChanged: true) }
        }
        if edit.stylesChanged { edits.noteStylesChanged() }
        if edit.metadataChanged { edits.noteWorkbookMetadataChanged() }
    }

    private func changedCells(in edit: DocumentEdit) -> Set<SheetCell> {
        guard case let .cells(sheet, _, after) = edit.payload else { return [] }
        return Set(after.keys.map { SheetCell(sheet: sheet, ref: $0) })
    }

    /// Recalculates what the edit touched.
    ///
    /// Addendum §11: `.keepCached` is rendered **stale**, never as a computed value. `apply(to:)`
    /// sets `CellFlags.staleCache` for exactly those cells and A4 draws the dotted underline, so
    /// a function we do not implement shows the file's own cached number *and says so* rather than
    /// showing a confident wrong one.
    private func recalculate(changed: Set<SheetCell>, includingVolatile: Bool = true) {
        guard !changed.isEmpty else { return }
        for cell in changed {
            guard let formula = workbook[cell.sheet]?.cells[cell.ref]?.formula else { continue }
            engine.setFormula(formula, at: cell, in: workbook)
        }
        let result = engine.recalculate(
            in: workbook, changed: changed, includingVolatile: includingVolatile
        )
        result.apply(to: &workbook)
    }

    // MARK: - Recalculation on open

    /// Bumped whenever ``workbook`` is replaced by an edit or a reload, so a background pass that
    /// started against an older value knows to throw its answer away.
    @ObservationIgnored private var workbookGeneration = 0

    /// What the last open recalculation did. `nil` until one has run. Tests read it; nothing in
    /// the app branches on it.
    public private(set) var lastOpenRecalculation: OpenRecalculation.Outcome?

    /// Puts right the totals of a workbook nobody ever calculated — see ``OpenRecalculation``.
    ///
    /// **Off the critical path, and never dirty.** The pass runs on a detached task over two
    /// `Sendable` values, so the first frame is drawn from the file's own cache exactly as before;
    /// the corrected values arrive a moment later and repaint. It is not a user edit: no
    /// `WorkbookEditTracker` note, no undo entry, no `markEdited()`. The document does not become
    /// unsaved because we did arithmetic the producer skipped.
    private func scheduleOpenRecalculation() {
        guard Flags.formulaEngineEnabled else { return }
        let decision = OpenRecalculation.decide(
            formulaCount: engine.graph.formulaCells.count, meta: workbook.meta
        )
        switch decision {
        case .trustCache:
            return
        case let .tooLarge(formulaCount):
            note(summary: OpenRecalculation.ceilingSummary(formulaCount: formulaCount), cellCount: 0)
        case .recalculate:
            let engine = engine
            let workbook = workbook
            let generation = workbookGeneration
            Task { [weak self] in
                let pass = await Task.detached(priority: .utility) {
                    OpenRecalculation.run(engine: engine, on: workbook)
                }.value
                guard let self, workbookGeneration == generation else { return }
                applyOpenRecalculation(pass.0, outcome: pass.1)
            }
        }
    }

    private func applyOpenRecalculation(_ result: RecalcResult, outcome: OpenRecalculation.Outcome) {
        lastOpenRecalculation = outcome
        guard outcome.changedAnything || outcome.keptCachedCount > 0 else { return }
        result.apply(to: &workbook)
        refreshSelectionDerived()
        guard outcome.changedAnything else { return }
        // Said in the session feed rather than in a banner: it is a fact about the file worth
        // being able to find later, not a decision the user has to make now.
        note(summary: OpenRecalculation.summary(outcome), cellCount: outcome.correctedCount)
    }

    /// Adds a neutral line to the sidebar's session feed.
    private func note(summary: String, cellCount: Int) {
        feedCounter += 1
        feed.insert(
            SessionFeedEntry(
                id: "recalc-\(feedCounter)",
                timestamp: timestampFormatter.string(from: Date()),
                summary: summary,
                cellCount: cellCount,
                signal: .neutral
            ),
            at: 0
        )
        if feed.count > 50 { feed.removeLast(feed.count - 50) }
    }

    // MARK: - Derived state

    public var isEditable: Bool {
        workbook.meta.readOnlyReason == nil && !syncState.isBlocked && syncState != .reloading
    }

    public var hasUnsavedEdits: Bool { !edits.isEmpty }

    public var activeSheet: Sheet? { workbook[activeSheetID] }

    private func refreshUndoState() {
        canUndo = undoStack.canUndo
        canRedo = undoStack.canRedo
        undoName = undoStack.undoName
        redoName = undoStack.redoName
    }

    private func refreshSelectionDerived() {
        guard let sheet = workbook[activeSheetID] else { return }
        selectionStats = SelectionStatistics.compute(
            selection: selection,
            sheet: sheet,
            styles: workbook.styles,
            dateSystem: workbook.meta.dateSystem,
            visible: selectionStats.visible
        )
        refreshFormulaBar(sheet)
        refreshToolbar()
    }

    /// The formula bar's state for the active cell.
    ///
    /// **Formulas only, and that is a Wave 1 limitation rather than a choice.** A5's `FormulaBar`
    /// renders its field as `"=" + state.text` — the property is documented as *"the formula
    /// source, without the leading `=`"* — so there is no way to put a literal in it: a text cell
    /// would read `=Line item`, which is not what the cell contains and is not even a valid
    /// formula. Passing only formula source uses the component as designed; the price is that a
    /// literal cell's bar is blank, and the literal is edited in the cell instead. The fix is a
    /// one-line change in `GlassUI` — let the caller supply the prefix — and it is A5's file.
    private func refreshFormulaBar(_ sheet: Sheet) {
        let cell = sheet.cells[selection.active]
        let names = definedNameItems
        formulaBar = FormulaBarState(
            nameBoxText: NameBoxLabel.text(for: selection.activeRange, definedNames: names),
            definedNames: names,
            text: cell?.formula ?? "",
            isEditing: formulaBar.isEditing,
            isExpanded: formulaBar.isExpanded,
            diagnostic: nil,
            isEditable: isEditable
        )
    }

    /// What the in-cell editor seeds with: the formula for a formula cell, the round-trippable
    /// literal for everything else.
    public func editText(at ref: CellRef) -> String {
        guard let sheet = workbook[activeSheetID], let cell = sheet.cells[ref] else { return "" }
        if let formula = cell.formula { return "=" + formula }
        let formatter = CellFormatter(
            styles: workbook.styles, dateSystem: workbook.meta.dateSystem, theme: .light
        )
        return formatter.editText(of: cell)
    }

    private func refreshToolbar() {
        guard let sheet = workbook[activeSheetID] else { return }
        let styleID = sheet.cells[selection.active]?.styleID ?? sheet.effectiveStyleID(at: selection.active)
        let style = workbook.styles[styleID]
        toolbar = ToolbarState(
            isBold: style.font.isBold,
            isItalic: style.font.isItalic,
            isUnderline: style.font.underline != .none,
            alignment: alignment(style.alignment.horizontal),
            wrapsText: style.alignment.wrapText,
            isMerged: sheet.merge(containing: selection.active) != nil,
            numberFormat: choice(workbook.styles.numberFormat(for: styleID)),
            fontName: style.font.name,
            fontSize: style.font.size,
            canPaste: pasteboardHasContent,
            hasSelection: true,
            isEditable: isEditable
        )
    }

    private var pasteboardHasContent: Bool {
        #if canImport(AppKit)
        Clipboard.hasContent()
        #else
        false
        #endif
    }

    public var definedNameItems: [DefinedNameItem] {
        workbook.definedNames.values
            .filter { !$0.isHidden }
            .sorted { $0.name < $1.name }
            .map { name in
                DefinedNameItem(
                    name: name.name,
                    rangeLabel: name.target.map { target in
                        WorkbookEditor.absoluteA1(
                            sheetName: target.sheet.flatMap { workbook[$0]?.name },
                            range: target.range
                        )
                    } ?? name.formula,
                    scope: name.scope.flatMap { workbook[$0]?.name }
                )
            }
    }

    public var sheetTabItems: [SheetTabItem] {
        workbook.sheets.map { sheet in
            SheetTabItem(
                id: sheet.id,
                name: sheet.name,
                colorIndex: nil,
                visibility: visibility(sheet.visibility),
                pendingChangeCount: pendingChangesBySheet[sheet.id] ?? 0
            )
        }
    }

    private func visibility(_ value: SheetVisibility) -> TabVisibility {
        switch value {
        case .visible: .visible
        case .hidden: .hidden
        case .veryHidden: .veryHidden
        }
    }

    private func alignment(_ value: CellAlignment.Horizontal) -> CellAlign {
        switch value {
        case .general: .general
        case .left, .justify, .distributed, .fill: .leading
        case .center, .centerContinuous: .center
        case .right: .trailing
        }
    }

    private func choice(_ format: NumberFormat) -> NumberFormatChoice {
        if format.isGeneral { return .general }
        if format.kind == .text { return .text }
        if format.isDateTime { return .date }
        let code = format.formatCode
        if code.contains("%") { return .percent }
        if code.contains("E+") || code.contains("E-") { return .scientific }
        if code.contains("$") || code.contains("€") || code.contains("£") || code.contains("¥") {
            return .currency
        }
        return .number
    }
}
