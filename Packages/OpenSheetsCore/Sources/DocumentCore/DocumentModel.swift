#if canImport(AppKit)
import AppKit
#endif
import Foundation
import GlassUI
import GridKit
import Observation
import SheetFormat
import SheetFormula
import SheetMCP
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
        didSet {
            guard selection != oldValue else { return }
            commitEditInFlight(typedAt: oldValue)
            refreshSelectionDerived()
        }
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
    /// The cell an editor currently owns — the in-cell editor, the formula bar, or both at once
    /// while they mirror each other. `nil` when nothing is being edited.
    ///
    /// One ref for both, because there is only ever one edit: the bar edits the active cell and
    /// the cell editor shows the same characters over the same cell. A second identity here would
    /// be a second place for them to disagree.
    public private(set) var editingRef: CellRef?
    /// The last edit this document refused, typed rather than as a sentence.
    ///
    /// The sentence goes on ``formulaBar`` as its diagnostic; this is the same fact in the form a
    /// caller can branch on. Cleared whenever the selection moves.
    public private(set) var lastEditRefusal: SheetError?
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
        autoRefresh: Bool = true,
        changeTracking: ChangeTracking = ChangeTracking(isEnabled: Flags.changeTrackingEnabled)
    ) {
        self.url = url
        self.workspaceURL = workspaceURL
        self.workbook = workbook
        self.session = session
        self.reader = reader
        self.writer = writer
        openedWorkbook = workbook
        openedAt = Date()
        baselineDate = openedAt
        isChangeTrackingEnabled = changeTracking.isEnabled
        checkpoints = changeTracking.isEnabled ? changeTracking.checkpoints : nil
        // Read once at init and written back on every set: the switch is global on purpose
        // (PLAN.md §1.3 — one switch, not one per document), and a document that re-read the
        // default on every access would make a hundred `UserDefaults` calls a frame.
        isChangeHighlightingEnabled = UserDefaults.standard
            .object(forKey: DocumentModel.highlightsDefaultsKey) as? Bool ?? true
        engine = FormulaEngine(workbook: workbook)
        activeSheetID = workbook.visibleSheets.first?.id ?? workbook.sheets.first?.id ?? SheetID(1)
        isWatching = autoRefresh
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        timestampFormatter = formatter
        selectionStats = SelectionStats(rangeLabel: "A1", values: [:])
        // The two things the grid tells the shell that are not `GridEvent`s: what is being typed
        // into a cell, so the formula bar can show the same characters, and an edit it had to
        // refuse, so the bar can say why rather than leaving a dead keystroke.
        grid.onEditorTextChanged = { [weak self] text in
            guard let self, formulaBar.text != text else { return }
            formulaBar.text = text
        }
        grid.onEditRefused = { [weak self] _, refusal in
            self?.noteEditRefusal(refusal)
        }
        refreshSelectionDerived()
        startPump()
        scheduleOpenRecalculation()
        adoptOpenedWorkbookAsBaseline()
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
        baselineTask?.cancel()
        baselineTask = nil
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
        baselineTask?.cancel()
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
            let wasEditable = isEditable
            syncState = to
            if to == .synced { clearPendingChanges() }
            // The state decides ``isEditable``, and the formula bar and the toolbar both render
            // from it. Without this, a file that goes read-only under the app leaves a bar that
            // still takes the caret and a toolbar that still offers Bold — controls that look
            // live and refuse on use, which is the worst of both.
            if isEditable != wasEditable { refreshSelectionDerived() }
        case let .refreshed(diff):
            await applyRefresh(diff)
        case .saved:
            edits.reset()
            writer?.clearStage(for: url)
            lastError = nil
            // A save does not move the baseline — that is the whole point of a baseline — but it
            // does mean the last debounced recompute may still be pending over a value the user
            // has now committed. Settle it so the chip is right just after ⌘S lands.
            scheduleBaselineRecompute(after: DocumentModel.refreshDebounce)
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
        // A refresh does **not** reset the baseline (PLAN.md §1.3): tracking accumulates across
        // as many agent writes as it takes until the user checkpoints. What it does do is make
        // the last answer wrong, so a fresh one is asked for — after a pause, because an agent
        // rewriting a file two hundred times a second (§1.9) arrives here as a stream of
        // refreshes and each one would otherwise start a pass the next one invalidates. It also
        // keeps this off the tail of the refresh itself, which is a frame the user is watching.
        scheduleBaselineRecompute(after: DocumentModel.refreshDebounce)

        guard !diff.isEmpty else { return }
        // §1.5's "refreshed in the last 6 s", which is what turns a background tab's dot accent
        // coloured. An empty diff is a file that was touched rather than changed, and it is not
        // news.
        lastRefreshAt = Date()
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
            // The cell editor opened — by double-click, F2, or a typed character. The bar joins
            // that edit rather than watching it: same ref, same text, live from here on.
            editingRef = ref
            formulaBar.isEditing = true
            formulaBar.diagnostic = nil
            formulaBar.text = seed ?? editText(at: ref)
        case let .commitEdit(ref, text, advance):
            // The editor has already closed itself, so this clears the flags only — dismissing it
            // again here would be harmless and dismissing it *before* it committed would not be.
            clearEditState()
            _ = commitEdit(at: ref, text: text, advance: advance)
        case .cancelEdit:
            clearEditState()
            refreshSelectionDerived()
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
        // Debounced, because this is called once per keystroke-sized edit and a diff per
        // keystroke is a diff nobody sees the result of. See ``scheduleBaselineRecompute(after:)``.
        scheduleBaselineRecompute(after: DocumentModel.localEditDebounce)
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
    ///
    /// `selectionBefore` is for the one caller that cannot let the selection speak for itself: a
    /// commit triggered *by* the selection moving has already lost the cell it was typed in, and
    /// undo has to put the caret back where the typing happened rather than where it ended up.
    @discardableResult
    public func commitEdit(
        at ref: CellRef,
        text: String,
        advance: AdvanceDirection? = nil,
        selectionBefore: GridSelection? = nil
    ) -> Bool {
        guard isEditable else { return false }
        guard let sheet = workbook[activeSheetID] else { return false }
        isCommitting = true
        defer { isCommitting = false }

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
            let isUnchanged = sheet.cells[ref]?.formula == source
            cell.formula = source
            // **The same formula, committed back, is not an edit.** Blanking the value to let the
            // recalculation refill it is right for a formula that changed and wrong for one that
            // did not: it makes the cell differ from itself, which turns every *"click the bar,
            // then click a cell"* into an undo step named "Typing" that undoes nothing. Literals
            // already avoid this — `WorkbookEditor.setCells` drops a write that changes nothing —
            // and this is the same rule reaching the case that could not see it.
            if !isUnchanged { cell.value = .empty }
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

        let selectionBefore = selectionBefore ?? selection
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
    ///
    /// Public so a view that caches something derived from the workbook — the grid's change
    /// tints, say — has a cheap key to cache it against. `@ObservationIgnored` on purpose: it is
    /// an identity, not a fact worth redrawing for, and the values it guards (``workbook``,
    /// ``baselineDiff``) are observed in their own right.
    @ObservationIgnored public private(set) var workbookGeneration = 0

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
                // `.userInitiated`, not `.utility`: until this lands the user is looking at the
                // producer's placeholder numbers, so it is not background maintenance.
                let pass = await Task.detached(priority: .userInitiated) {
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
        noteWorkbookRecalculated()
        guard outcome.changedAnything else { return }

        // Said in the session feed rather than in a banner: it is a fact about the file worth
        // being able to find later, not a decision the user has to make now.
        //
        // When the pass followed a refresh, it is folded into *that* entry instead of adding a
        // second one. The agent's edit and the recalculation it made necessary are one event in
        // the file's history, and two lines per agent edit is how a feed stops being read.
        if let first = feed.first, first.id.hasPrefix("refresh-") {
            feed[0].summary += " · \(outcome.correctedCount) recalculated"
            return
        }
        note(summary: OpenRecalculation.summary(outcome), cellCount: outcome.correctedCount)
    }

    /// Adds a neutral line to the sidebar's session feed.
    private func note(summary: String, cellCount: Int, id: String = "recalc") {
        feedCounter += 1
        feed.insert(
            SessionFeedEntry(
                id: "\(id)-\(feedCounter)",
                timestamp: timestampFormatter.string(from: Date()),
                summary: summary,
                cellCount: cellCount,
                signal: .neutral
            ),
            at: 0
        )
        if feed.count > 50 { feed.removeLast(feed.count - 50) }
    }

    /// Records that opening this file granted its parent folder (PLAN.md §1.1).
    ///
    /// A grant is the difference between Claude Code answering and Claude Code refusing with
    /// `grant.outsideWorkspace`, so it is worth a line — and it is a permission the user now has,
    /// which is worth a line for the opposite reason. The sidebar's Claude panel already shows the
    /// workspace path; this is the sentence next to it that says when it became reachable.
    public func noteWorkspaceGranted(_ folder: URL) {
        note(
            summary: "Granted \(folder.lastPathComponent) to Claude Code — "
                + "manage workspaces in Settings",
            cellCount: 0,
            id: "grant"
        )
    }

    // MARK: - Baseline and change tracking

    /// Where the *before* side of ``baselineDiff`` comes from. Starts at
    /// ``BaselineSource/asOpened`` and only ever moves because the user asked (PLAN.md §1.3).
    public private(set) var baselineSource: BaselineSource = .asOpened

    /// When the baseline was taken — the chip's *"Since opened · 09:41"*.
    public private(set) var baselineDate: Date

    /// What has changed since the baseline.
    ///
    /// `nil` means *no answer yet*: change tracking is off, or the first pass has not landed.
    /// ``WorkbookDiff/empty`` means *nothing has changed*, which is a different thing and the
    /// chip renders it differently (it hides). A view that conflated the two would flash the
    /// chip on for a frame at every open.
    public private(set) var baselineDiff: WorkbookDiff?

    /// Whether the grid paints the standing tints.
    ///
    /// Global rather than per document, and deliberately: this is one switch for "show me what
    /// changed", and a user who turns it off in one window means it in all of them. Mirrored
    /// into `OSChangeHighlights` so the answer survives a relaunch.
    public var isChangeHighlightingEnabled: Bool {
        didSet {
            guard isChangeHighlightingEnabled != oldValue else { return }
            UserDefaults.standard.set(
                isChangeHighlightingEnabled, forKey: DocumentModel.highlightsDefaultsKey
            )
        }
    }

    /// When a refresh last brought a **non-empty** change in from disk.
    ///
    /// PLAN.md §1.5 uses it for one thing: a file tab shows the accent dot for six seconds after
    /// an agent wrote to the file, so a background tab can say "something happened here" without
    /// the window having to keep a second history.
    public private(set) var lastRefreshAt: Date?

    /// Whether ``BaselineSource/checkpoint`` is a baseline this document can actually produce.
    ///
    /// The panel offers the source list, and offering a checkpoint that does not exist is how a
    /// menu item becomes a no-op the user blames themselves for.
    public private(set) var isCheckpointAvailable = false

    /// Reads the committed version of this file, for ``BaselineSource/gitHEAD``.
    ///
    /// Injected rather than built in, because `DocumentCore` has no business knowing what git
    /// is: the adapter that runs the subprocess lives one layer up and installs itself here.
    /// `nil` — the wave-1 state — leaves the whole git path dormant.
    @ObservationIgnored public var gitBaselineProvider: (@Sendable (URL) async -> Workbook?)? {
        didSet { probeGitBaseline() }
    }

    /// Whether the git source is worth offering. Answered asynchronously, once, by probing
    /// ``gitBaselineProvider`` when one is installed; `false` until then and whenever the probe
    /// comes back empty (no repository, untracked file, no `git`).
    public private(set) var isGitBaselineAvailable = false

    /// How many baseline diffs have actually been computed.
    ///
    /// Tests read it — it is the only way to *observe* a debounce, as opposed to hoping for one.
    /// Nothing in the app branches on it, exactly like ``lastOpenRecalculation``.
    public private(set) var baselineComputeCount = 0

    /// Aggregate counts for the title-bar chip. Zero-filled while there is no diff.
    public var baselineCounts: BaselineCounts { BaselineTracker.counts(for: baselineDiff) }

    /// PLAN.md §1.2 step 8. Marks here as the new *before*.
    ///
    /// Order matters and is the order below: the snapshot is taken **first**, because a baseline
    /// that has moved with no bytes behind it is a baseline that silently degrades to
    /// ``BaselineSource/asOpened`` at the next launch, and the user would have no way to tell.
    ///
    /// The in-memory baseline is the workbook *on screen*, per contract C2, while the snapshot
    /// is the bytes *on disk*. With unsaved edits those differ, so a checkpoint set over unsaved
    /// work reads slightly differently after a relaunch (the edits show as changes, because from
    /// the file's point of view they are). Forcing a save first would be the alternative, and
    /// silently saving because the user asked for a bookmark is the worse surprise.
    public func setCheckpoint() async {
        guard isChangeTrackingEnabled else { return }
        let record = try? await session.captureSnapshot(reason: .checkpoint, summary: "checkpoint")
        // Nothing to copy and no way to make a copy — an unreadable file we also cannot save.
        // There is no checkpoint to be had here, so claim none.
        guard record != nil || syncState.allowsSaving else { return }
        checkpoints?.store(record?.id, for: url)
        isCheckpointAvailable = record != nil
        adoptCurrentWorkbookAsBaseline(source: .checkpoint, date: record?.takenAt ?? Date())
    }

    /// Switches which question the chip is answering.
    ///
    /// A source that cannot produce a baseline leaves the current one alone. That rule is the
    /// whole reason this is `async`: finding out whether git has a committed version of this
    /// file means asking git, and a model that flipped its source first and discovered the
    /// answer afterwards would spend a moment claiming a baseline it does not have.
    public func setBaselineSource(_ source: BaselineSource) async {
        guard isChangeTrackingEnabled else { return }
        switch source {
        case .asOpened:
            setBaseline(openedWorkbook, source: .asOpened, date: openedAt)
        case .checkpoint:
            guard let checkpoints, let restored = await checkpointBaseline(from: checkpoints) else {
                isCheckpointAvailable = false
                return
            }
            isCheckpointAvailable = true
            setBaseline(restored.workbook, source: .checkpoint, date: restored.takenAt)
        case .gitHEAD:
            guard let committed = await gitBaselineWorkbook() else {
                isGitBaselineAvailable = false
                return
            }
            setBaseline(committed, source: .gitHEAD, date: Date())
        }
    }

    // MARK: - Baseline machinery

    @ObservationIgnored private let isChangeTrackingEnabled: Bool
    @ObservationIgnored private let checkpoints: CheckpointStore?
    /// The value the file had when this document opened — the ``BaselineSource/asOpened``
    /// baseline, kept so switching *back* to it is possible after a checkpoint.
    @ObservationIgnored private let openedWorkbook: Workbook
    @ObservationIgnored private let openedAt: Date
    @ObservationIgnored private var baselineWorkbook: Workbook?
    /// Bumped whenever the baseline itself moves, so a diff computed against the previous one is
    /// discarded rather than shown against the new one.
    @ObservationIgnored private var baselineGeneration = 0
    /// The ``workbookGeneration`` the baseline was taken *from*, when it was taken from the live
    /// workbook rather than from bytes. `nil` otherwise. See ``noteWorkbookRecalculated()``.
    @ObservationIgnored private var baselineTakenFromWorkbookGeneration: Int?
    @ObservationIgnored private var baselineTask: Task<Void, Never>?
    @ObservationIgnored private var isRecomputingBaseline = false
    @ObservationIgnored private var baselineRecomputeQueued = false
    /// The workbook the availability probe already fetched, kept so the first switch to
    /// ``BaselineSource/gitHEAD`` does not pay for the same subprocess and parse twice. Consumed
    /// on use: a second switch asks git again, because by then there may be a new commit.
    @ObservationIgnored private var probedGitBaseline: Workbook?

    private static let highlightsDefaultsKey = "OSChangeHighlights"
    /// Long enough that a burst of typing is one pass, short enough that the chip feels live.
    private static let localEditDebounce = Duration.milliseconds(500)
    /// The watcher's own coalescing window (`FileWatcher.Configuration`), which is the natural
    /// granularity for news arriving from disk: anything closer together than that reached us as
    /// one event anyway.
    private static let refreshDebounce = Duration.milliseconds(150)

    private func adoptOpenedWorkbookAsBaseline() {
        guard isChangeTrackingEnabled else { return }
        adoptCurrentWorkbookAsBaseline(source: .asOpened, date: openedAt)
        restorePersistedCheckpoint()
    }

    /// Takes the workbook on screen as the new baseline.
    ///
    /// The diff is set to ``WorkbookDiff/empty`` rather than recomputed, because the two sides
    /// are the same value: spending a pass over a million cells to prove that nothing differs
    /// from itself would be the most expensive way to learn the least.
    private func adoptCurrentWorkbookAsBaseline(source: BaselineSource, date: Date) {
        cancelBaselineWork()
        baselineGeneration &+= 1
        baselineWorkbook = workbook
        baselineTakenFromWorkbookGeneration = workbookGeneration
        baselineSource = source
        baselineDate = date
        baselineDiff = .empty
    }

    /// Takes a workbook from somewhere else — a snapshot's bytes, git's — as the baseline.
    private func setBaseline(_ candidate: Workbook, source: BaselineSource, date: Date) {
        cancelBaselineWork()
        baselineGeneration &+= 1
        baselineWorkbook = candidate
        baselineTakenFromWorkbookGeneration = nil
        baselineSource = source
        baselineDate = date
        baselineDiff = nil
        scheduleBaselineRecompute()
    }

    private func cancelBaselineWork() {
        baselineTask?.cancel()
        baselineTask = nil
        baselineRecomputeQueued = false
    }

    /// Asks for a fresh answer, eventually.
    ///
    /// Two mechanisms, and they do different jobs. `after` debounces the *request*, so ten
    /// keystrokes in half a second are one pass. ``isRecomputingBaseline`` serialises the
    /// *work*, so a request that arrives while a pass is running is remembered rather than
    /// started — which is what stops an agent writing two hundred times a second (PLAN.md §1.9)
    /// from turning into two hundred concurrent walks of the workbook. At most one diff runs at
    /// a time, whatever the burst looks like.
    private func scheduleBaselineRecompute(after delay: Duration = .zero) {
        guard isChangeTrackingEnabled, baselineWorkbook != nil else { return }
        guard !isRecomputingBaseline else {
            baselineRecomputeQueued = true
            return
        }
        baselineTask?.cancel()
        // **Detached, so the wait does not queue behind — or ahead of — anything on the main
        // actor.** A plain `Task` here inherits this actor, which means asking for a recompute
        // enqueues a main-actor job at the very moment `applyRefresh` is finishing; the pump's
        // next event (the one that moves the document out of `RELOADING`) then waits behind it.
        // That is a real, measurable widening of a window the app already has, and it showed up
        // as `CoreLoopTests.autoRefreshAppliesWithoutBeingAsked` failing under load. Nothing
        // here needs the main actor until the answer comes back.
        baselineTask = Task.detached(priority: .utility) { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await self?.recomputeBaselineDiff()
        }
    }

    private func recomputeBaselineDiff() async {
        guard let baseline = baselineWorkbook else { return }
        let current = workbook
        let startedAtWorkbook = workbookGeneration
        let startedAtBaseline = baselineGeneration
        isRecomputingBaseline = true
        let result = await BaselineTracker.diff(baseline: baseline, current: current)
        isRecomputingBaseline = false
        baselineComputeCount &+= 1

        // The guard the whole design turns on: a pass that started against a workbook, or a
        // baseline, that has since moved has computed the answer to a question nobody is asking
        // any more. Landing it would show the user the state before their last edit — and it
        // would do so intermittently, which is the worst kind of wrong.
        if startedAtWorkbook == workbookGeneration, startedAtBaseline == baselineGeneration {
            // Normalised, so `baselineDiff == .empty` means "nothing changed" wherever a caller
            // asks. The differ reports one `SheetDiff` per matched sheet whether or not anything
            // in it moved, so an unchanged workbook comes back as a diff that *is* empty without
            // *equalling* ``WorkbookDiff/empty`` — a distinction that would make every consumer
            // remember to write `isEmpty`, and eventually one of them would not.
            baselineDiff = result.isEmpty ? .empty : result
        }
        if baselineRecomputeQueued {
            baselineRecomputeQueued = false
            scheduleBaselineRecompute()
        }
    }

    /// The open recalculation moved cells the *producer* left uncomputed — not cells anyone
    /// edited (see ``scheduleOpenRecalculation()``).
    ///
    /// When the baseline is still the value this document opened with, it has to move with
    /// them. Otherwise the chip greets the user with *"+0 ~500 −0"* for arithmetic the app did
    /// to itself, before they have touched anything. Any other baseline — a checkpoint, git
    /// HEAD, or an as-opened baseline the file has already moved past — keeps its ground, and
    /// the corrected values show up as the changes they are.
    private func noteWorkbookRecalculated() {
        guard isChangeTrackingEnabled else { return }
        guard baselineSource == .asOpened,
              baselineTakenFromWorkbookGeneration == workbookGeneration
        else {
            scheduleBaselineRecompute()
            return
        }
        adoptCurrentWorkbookAsBaseline(source: .asOpened, date: baselineDate)
    }

    /// Puts back the checkpoint the last session left behind (PLAN.md §1.7).
    ///
    /// Fire and forget, and silent about every way it can fail: an evicted snapshot, a corrupt
    /// archive, bytes that no longer parse. All of them leave the document on the as-opened
    /// baseline it already has, which is the honest fallback — and none of them is a failure the
    /// user caused, so none of them touches ``lastError``.
    /// Detached, like every other piece of baseline work: this runs during `init`, and a
    /// main-actor job created there queues ahead of the session pump's first event.
    private func restorePersistedCheckpoint() {
        guard let checkpoints else { return }
        let generation = baselineGeneration
        let target = url
        Task.detached(priority: .utility) { [weak self] in
            guard let restored = await checkpoints.checkpointBaseline(for: target) else { return }
            await self?.adoptRestoredCheckpoint(restored, takenAtBaselineGeneration: generation)
        }
    }

    /// The main-actor half of ``restorePersistedCheckpoint()``.
    ///
    /// The generation check is the point: the user may have set a fresh checkpoint, or switched
    /// source, in the time it took to decompress and parse the snapshot. Their choice wins.
    private func adoptRestoredCheckpoint(
        _ restored: (workbook: Workbook, takenAt: Date),
        takenAtBaselineGeneration generation: Int
    ) {
        guard baselineGeneration == generation else { return }
        isCheckpointAvailable = true
        setBaseline(restored.workbook, source: .checkpoint, date: restored.takenAt)
    }

    /// Hops the checkpoint read off the main actor.
    ///
    /// `nonisolated` is what does it: a `nonisolated async` method called from the main actor
    /// runs on the generic executor, so the SQLite read, the gunzip and the parse all happen
    /// away from the frame. Calling the store's method directly from a `@MainActor` context
    /// would inherit this actor and block the grid for the length of a workbook parse.
    private nonisolated func checkpointBaseline(
        from store: CheckpointStore
    ) async -> (workbook: Workbook, takenAt: Date)? {
        await store.checkpointBaseline(for: url)
    }

    private func gitBaselineWorkbook() async -> Workbook? {
        if let probed = probedGitBaseline {
            probedGitBaseline = nil
            return probed
        }
        guard let provider = gitBaselineProvider else { return nil }
        return await provider(url)
    }

    /// Finds out whether git has a committed version of this file, once, in the background.
    ///
    /// Runs when a provider is installed rather than at init, because the provider arrives after
    /// init — the app layer builds it and hands it over on the tab-ready path. The answer is
    /// kept (see ``probedGitBaseline``) so choosing the source costs nothing the second time.
    private func probeGitBaseline() {
        guard isChangeTrackingEnabled, let provider = gitBaselineProvider else {
            isGitBaselineAvailable = false
            return
        }
        let target = url
        Task.detached(priority: .utility) { [weak self] in
            let committed = await provider(target)
            await self?.noteGitBaseline(committed)
        }
    }

    /// The main-actor half of ``probeGitBaseline()``.
    private func noteGitBaseline(_ committed: Workbook?) {
        probedGitBaseline = committed
        isGitBaselineAvailable = committed != nil
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
    /// **The bar shows what the cell holds, whatever kind of thing that is.** It used to show
    /// `cell.formula` and nothing else, because `FormulaBarState.text` was documented as formula
    /// source and the component put the `=` back itself — so every text cell and every typed
    /// number arrived at the bar as an empty string. That contract is gone: the text now carries
    /// its own prefix, and it comes from ``editText(at:)``, which is *the same call that seeds
    /// the in-cell editor*. One source of truth, so the two fields cannot disagree about what is
    /// in the cell.
    ///
    /// `isEditable` is the document's own writability **and** the cell's: a cell a spill wrote
    /// into is readable here and refused on click, exactly as the grid refuses it.
    private func refreshFormulaBar(_ sheet: Sheet) {
        let names = definedNameItems
        lastEditRefusal = nil
        formulaBar = FormulaBarState(
            nameBoxText: NameBoxLabel.text(for: selection.activeRange, definedNames: names),
            definedNames: names,
            text: formulaBarText(at: selection.active),
            isEditing: formulaBar.isEditing,
            isExpanded: formulaBar.isExpanded,
            diagnostic: nil,
            isEditable: isEditable && sheet.editRefusal(at: selection.active) == nil
        )
    }

    /// What the in-cell editor seeds with: the formula for a formula cell, the round-trippable
    /// literal for everything else.
    ///
    /// Round-trippable rather than formatted, and that distinction is the whole point: a cell
    /// showing `£1,234.50` edits as `1234.5`, because putting the formatted string back through
    /// the parser is how a currency column turns into a column of text.
    public func editText(at ref: CellRef) -> String {
        guard let sheet = workbook[activeSheetID], let cell = sheet.cells[ref] else { return "" }
        if let formula = cell.formula { return "=" + formula }
        let formatter = CellFormatter(
            styles: workbook.styles, dateSystem: workbook.meta.dateSystem, theme: .light
        )
        return formatter.editText(of: cell)
    }

    /// What the formula bar shows for `ref`.
    ///
    /// ``editText(at:)``, except for a cell a spill wrote into: that shows the **anchor's**
    /// formula, because the anchor is what produced the number sitting there. Showing the number
    /// would invite the user to retype it, and retyping it is precisely the edit that has to be
    /// refused.
    public func formulaBarText(at ref: CellRef) -> String {
        guard let sheet = workbook[activeSheetID] else { return "" }
        if let owner = sheet.spillOwner(of: ref), owner.owns(ref) { return editText(at: owner.anchor) }
        return editText(at: ref)
    }

    // MARK: - The formula bar's edit

    /// The formula bar took the caret — or was clicked while it could not take it.
    ///
    /// Returns `false` when the edit cannot start, having already put the reason on the bar. The
    /// two reasons are a workbook that is not writable and a cell whose value belongs to a spill
    /// anchor; the second is the same refusal ``GridKit/GridHostView/beginEdit(at:seed:takingFocus:)``
    /// makes, from the same rule, so the bar and the cell cannot answer differently.
    @discardableResult
    public func beginFormulaBarEdit() -> Bool {
        guard isEditable else {
            formulaBar.diagnostic = notEditableReason
            return false
        }
        let ref = selection.active
        if let refusal = workbook[activeSheetID]?.editRefusal(at: ref) {
            noteEditRefusal(refusal)
            #if canImport(AppKit)
            NSSound.beep()
            #endif
            return false
        }
        editingRef = ref
        formulaBar.isEditing = true
        formulaBar.diagnostic = nil
        // The in-cell editor comes up as a **mirror**, not as the editor: it shows the same
        // characters over the cell they belong to and leaves the keyboard alone, so the caret
        // stays on the character the user clicked in the bar.
        if !grid.isEditing {
            grid.beginEdit(at: ref, seed: formulaBar.text, takingFocus: false)
        }
        return true
    }

    /// Why the bar cannot take the caret, in one sentence.
    ///
    /// Deliberately short of naming *which* read-only reason applies when the workbook itself
    /// does not carry one: a file another app has locked and a format with no writer both reach
    /// the model as `.readOnly`, and the session keeps the distinction rather than this. The sync
    /// chip already shows the specific reason; a sentence here that guessed would be wrong often
    /// enough to be worse than a general one.
    private var notEditableReason: String {
        if let reason = workbook.meta.readOnlyReason {
            return SheetError.writeRefused(reason: reason).message
        }
        switch syncState {
        case .readOnly, .locked: return "This workbook is open read-only, so its cells cannot be edited."
        case .missing: return "This file is no longer on disk. Save a copy of it before editing."
        case .reloading: return "This workbook is reloading from disk."
        default: return "This workbook cannot be edited right now."
        }
    }

    /// A keystroke in the formula bar. Mirrors it into the cell.
    public func formulaBarTextChanged(_ text: String) {
        guard formulaBar.text != text else { return }
        formulaBar.text = text
        if grid.isEditing { grid.editorText = text }
    }

    /// Return, Tab, or the tick.
    ///
    /// Goes through ``commitEdit(at:text:advance:)`` — the same call the in-cell editor's commit
    /// arrives on — so parsing, formula validation, recalculation, the dirty-part set and undo
    /// all behave identically whichever field the text was typed in. There is one write path.
    @discardableResult
    public func commitFormulaBarEdit(_ text: String, advance: AdvanceDirection? = .down) -> Bool {
        guard isEditable else { return false }
        let ref = editingRef ?? selection.active
        guard commitEdit(at: ref, text: text, advance: advance) else {
            // Refused — a formula that does not parse, or text over the cell limit. The reason is
            // on the bar already; the edit stays **open**, because the alternative is throwing
            // away what the user typed at the moment they most need to see it.
            return false
        }
        endEdit()
        // `commitEdit` walks a multi-cell selection itself; a single cell needs the grid's
        // navigator, which is what makes Return skip a hidden row and step out of a merge. That
        // is the same split `GridNavigator.advance` makes, and the same one the in-cell editor
        // gets for free through `GridHostView.finishEdit`.
        if let advance, selection.isSingleCell { grid.advance(advance, from: selection) }
        return true
    }

    /// Escape, or the cross: the cell keeps what it had.
    public func cancelFormulaBarEdit() {
        endEdit()
        refreshSelectionDerived()
    }

    /// Answers the formula bar's **editing** actions — the four that are the document's business.
    ///
    /// Returns `false` for the three that are the shell's: navigation, the `fx` picker and the
    /// disclosure all need the window's palette and its layout state, and none of them is an
    /// edit.
    ///
    /// One switch rather than two. This mapping used to live in `DocumentWindow`, where no test
    /// in this package could reach it — so the model was tested by calling its methods directly,
    /// the view was tested by watching which actions it emitted, and *the join between them* was
    /// the one part of the path nothing covered. That is exactly where the formula-eating bug
    /// lived.
    @discardableResult
    public func perform(_ action: FormulaBarAction) -> Bool {
        switch action {
        case .beginEditing:
            beginFormulaBarEdit()
        case let .textChanged(text):
            formulaBarTextChanged(text)
        case let .commit(text, advance):
            commitFormulaBarEdit(text, advance: advanceDirection(advance))
            // The caret goes back to the grid, so the arrow keys that follow a commit move the
            // selection instead of moving through a formula that is no longer being edited.
            grid.focus()
        case .cancel:
            cancelFormulaBarEdit()
            grid.focus()
        case .navigate, .selectDefinedName, .insertFunction, .toggleExpanded:
            return false
        }
        return true
    }

    private func advanceDirection(_ advance: FormulaBarAdvance) -> AdvanceDirection? {
        switch advance {
        case .down: .down
        case .up: .up
        case .forward: .forward
        case .backward: .backward
        case .stay: nil
        }
    }

    /// Excel's rule, and already the grid's: **moving the selection commits the edit in flight.**
    ///
    /// `GridHostView.paneMouseDown` and `beginHeaderInteraction` commit the editor before they
    /// move the caret, so the selections that reach here with an edit still open are the ones
    /// that did not come from the grid — the name box, a defined name, the ⌘K palette, a jump
    /// from the diff panel. Committing those the same way is what makes "type in the bar, jump
    /// to a named range" keep the typing.
    ///
    /// Cancelling instead is defensible — Numbers discards — but it would make one keystroke mean
    /// two different things depending on which control happened to move the selection, and the
    /// half that discards is the half that loses work.
    private func commitEditInFlight(typedAt previous: GridSelection) {
        // A commit moves the selection itself, to advance the caret. That is not navigation and
        // must not re-enter the commit it came from.
        guard !isCommitting, let ref = editingRef, isEditable else { return }
        let text = formulaBar.text
        endEdit()
        _ = commitEdit(at: ref, text: text, advance: nil, selectionBefore: previous)
    }

    /// Forgets the edit in progress and takes the mirror off the screen, saying nothing.
    ///
    /// Not ``GridKit/GridController/cancelEdit()``, which would emit a cancel for an edit that is
    /// about to land, and not `commitEdit`, which would write it a second time.
    private func endEdit() {
        clearEditState()
        grid.dismissEdit()
    }

    private func clearEditState() {
        editingRef = nil
        formulaBar.isEditing = false
    }

    /// True for the duration of ``commitEdit(at:text:advance:selectionBefore:)``. See
    /// ``commitEditInFlight(typedAt:)``.
    @ObservationIgnored private var isCommitting = false

    /// Puts a refusal where the user is already looking. The grid has beeped and scrolled to the
    /// anchor; without this the keystroke is indistinguishable from a broken control.
    private func noteEditRefusal(_ refusal: SheetError) {
        lastEditRefusal = refusal
        formulaBar.diagnostic = refusal.message
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
