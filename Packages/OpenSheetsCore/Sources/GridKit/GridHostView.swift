import AppKit
import Foundation
import SheetModel

/// The whole grid: a scroll view, a flipped document view, floating headers, up to three frozen
/// pane views, a divider overlay, and the in-cell editor.
///
/// This is the object ``GridView`` wraps for SwiftUI, and the one that owns every piece of
/// interaction state. The renderer draws; this decides what to draw and what a click means.
///
/// # Layout
///
/// The scroll view fills the host. Its `contentInsets` reserve the header strip, the frozen band
/// **and** whatever the shell asked for in ``GridOptions/contentInsets``, so the document view
/// scrolls underneath all three without any of them needing to move.
///
/// **Everything except the document view is a plain subview of the host, framed in the host's own
/// coordinate space.** Headers and frozen panes do not slide; they redraw with a different scroll
/// origin. That makes the layout deterministic, which is worth more than saving a redraw.
///
/// They were once `addFloatingSubview(_:for:)` children, and that was a real defect: AppKit
/// re-parents a floating subview into a container it pins to the clip view's visible rect, which
/// `contentInsets` has *already* offset — so every header landed `(insets.left, insets.top)` too
/// far right and too far down, the row numbers sat on column A and the column letters sat one
/// column across from their data. Nothing floats now, and
/// `GridHostViewTests.headersLineUpWithTheCellsTheyLabelInARealWindow` holds it that way — in a
/// real `NSWindow`, because AppKit's floating pass never runs on a detached view and that is
/// precisely why 134 tests missed it.
@MainActor
public final class GridHostView: NSView {
    // MARK: - State

    /// Everything being drawn. Assign through ``update(model:)``.
    public private(set) var model: GridRenderModel

    let renderer: GridRenderer
    let headerRenderer: GridHeaderRenderer

    /// Drives the "Claude changed this" tint, and stops itself when the tint reaches zero.
    public let flashController: FlashController

    /// Column and row data indices, for `⌘`-arrow.
    public let blocks = DataBlockIndex()

    /// Where the grid sends everything it cannot do itself.
    public var onEvent: GridEventHandler?

    /// Called when ``beginEdit(at:seed:)`` refuses, with the cell and the reason.
    ///
    /// Separate from ``onEvent`` rather than a ``GridEvent`` case: a refusal is not something
    /// the shell has to act on to stay correct, and adding a case would make every existing
    /// `switch` over `GridEvent` stop compiling for a message it can choose to ignore.
    public var onEditRefused: ((CellRef, SheetError) -> Void)?

    // MARK: - Views

    private let scrollView = NSScrollView()
    private let documentView = GridDocumentView()
    private let cornerView = GridCornerView()
    private let columnHeaderView = GridColumnHeaderView()
    private let rowHeaderView = GridRowHeaderView()
    private let frozenOverlay = GridFrozenOverlayView()
    private var frozenPaneViews: [GridPane: GridPaneView] = [:]
    /// The in-cell editor. Exposed so the shell can drive the formula bar from the same text.
    public let editor = CellEditor()

    // MARK: - Interaction

    private enum DragMode {
        case none
        case selecting
        case fillHandle(source: CellRange)
        /// A drag across the column letters or the row numbers, selecting whole columns or rows.
        case headerSelecting(axis: HeaderAxis)
    }

    private var dragMode: DragMode = .none
    private var fillTarget: CellRange?
    private var autoscrollTimer: Timer?
    private var lastDragWindowPoint: CGPoint = .zero

    // MARK: - Accessibility

    /// The synthesised element window.
    ///
    /// `nonisolated(unsafe)` because `NSView`'s accessibility getters are nonisolated in the SDK
    /// and must answer synchronously. It is written only on the main actor, in
    /// ``refreshAccessibilityTree()``, and read only from accessibility callbacks, which the
    /// accessibility runtime delivers on the main thread. That is a narrower and more honest
    /// claim than `@unchecked Sendable` on the elements themselves would be.
    nonisolated(unsafe) var accessibilityTree = GridAccessibilityTree()

    /// Whether to build the element tree at all. Follows VoiceOver, and can be forced on by a
    /// test — building a few thousand elements per scroll frame for nobody is pure waste.
    nonisolated(unsafe) var buildsAccessibilityTree = NSWorkspace.shared.isVoiceOverEnabled

    /// The scroll view's insets, readable from the accessibility builder.
    var scrollViewContentInsets: NSEdgeInsets { scrollView.contentInsets }

    /// Forces the accessibility tree on, for tests and for a shell that wants it always live.
    public func setBuildsAccessibilityTree(_ enabled: Bool) {
        buildsAccessibilityTree = enabled
        refreshAccessibilityTree()
    }
    private var lastEmittedVisibleRange: CellRange?
    private var measuredHeaderWidth: Double

    // MARK: - Init

    public init(model: GridRenderModel) {
        self.model = model
        renderer = GridRenderer(theme: model.theme)
        headerRenderer = GridHeaderRenderer(theme: model.theme)
        flashController = FlashController(duration: model.theme.flashDuration)
        measuredHeaderWidth = model.theme.headerWidth
        super.init(frame: .zero)
        blocks.update(cells: model.sheet.cells)
        buildHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            autoscrollTimer?.invalidate()
            flashController.cancel()
        }
    }

    override public var isFlipped: Bool { true }

    private func buildHierarchy() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(cgColor: model.theme.canvasBackground.cgColor) ?? .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.allowsMagnification = false
        // The grid scroll must be 1:1 with the trackpad (PLAN.md §3.3), so nothing here animates.
        scrollView.contentView.postsBoundsChangedNotifications = true

        documentView.host = self
        scrollView.documentView = documentView
        addSubview(scrollView)

        cornerView.host = self
        columnHeaderView.host = self
        rowHeaderView.host = self
        frozenOverlay.host = self
        editor.onCommit = { [weak self] ref, text, advance in
            self?.finishEdit(ref: ref, text: text, advance: advance)
        }
        editor.onCancel = { [weak self] ref in
            self?.onEvent?(.cancelEdit(ref: ref))
            self?.focusDocument()
        }

        for pane in [GridPane.corner, .top, .left] {
            let view = GridPaneView(pane: pane)
            view.host = self
            frozenPaneViews[pane] = view
            addSubview(view)
        }
        addSubview(frozenOverlay)
        // Plain subviews of the host, above the scroll view. Every one of them is re-framed in
        // host coordinates on every layout pass, so none of them ever needed AppKit's floating
        // behaviour — and asking for it put them all `contentInsets` out of place. See the type's
        // note.
        addSubview(columnHeaderView)
        addSubview(rowHeaderView)
        addSubview(cornerView)
        addSubview(editor)
        clipEveryPaneToItself()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        flashController.setTicker(DisplayLinkTicker(view: documentView))
        flashController.onInvalidate = { [weak self] range in
            guard let self else { return }
            // The renderer reads the tint off the *model*, so the controller's state has to land
            // there before the repaint it is asking for. Without this line the display link runs,
            // the cells are invalidated, and every one of them draws with `flash.isActive == false`
            // — the change highlight decays perfectly and is never once visible.
            syncFlashIntoModel()
            invalidate(range)
        }
    }

    /// Says out loud the thing ``GridPane`` already claims: **each pane is clipped to its own
    /// rectangle**.
    ///
    /// `NSView.clipsToBounds` defaults to `false` on macOS 14 and later, so a view may draw
    /// wherever its `dirtyRect` reaches — and a subview's `dirtyRect` is the *host's* damaged
    /// region expressed in the subview's coordinates, which for a 15pt-tall frozen strip at
    /// `(184, 22)` is a thousand points wide and six hundred tall. ``GridRenderer/draw(_:into:
    /// viewRect:sheetOrigin:model:)`` starts by filling `viewRect` with the canvas, because a pane
    /// owns every pixel of itself. Unclipped, that fill owns every pixel of the *window*.
    ///
    /// The result was not subtle and it is worth naming, because it looks like a data bug rather
    /// than a drawing one: the panes draw in subview order, so `.corner` painted the whole window
    /// and drew A1, `.top` painted over that and drew row 1, `.left` painted over *that* and drew
    /// column A — and the frame ended with a sheet that appeared to contain nothing but its first
    /// column. Column B survived only because ``GridRenderer`` probes one cell past a pane's edge
    /// for spilling text. Row 1 and every column from C rightwards were drawn, correctly, and then
    /// erased by the next pane a few microseconds later.
    private func clipEveryPaneToItself() {
        documentView.clipsToBounds = true
        for view in frozenPaneViews.values { view.clipsToBounds = true }
        frozenOverlay.clipsToBounds = true
        columnHeaderView.clipsToBounds = true
        rowHeaderView.clipsToBounds = true
        cornerView.clipsToBounds = true
    }

    /// Copies the live flash state and the moment to evaluate it at into the render model.
    ///
    /// Called on every tick and on every model update, because ``update(model:)`` replaces the
    /// whole value and would otherwise drop a flash mid-decay the first time the selection moved.
    private func syncFlashIntoModel() {
        model.flash = flashController.state
        model.flashTime = flashController.now()
    }

    // MARK: - Model

    /// Replaces everything being drawn and lays out again.
    ///
    /// Cheap when only the selection changed: the sheet is a value type, so the comparison that
    /// decides whether to rebuild the data index is a pointer comparison in the common case.
    public func update(model newModel: GridRenderModel) {
        let cellsChanged = model.sheet.cells != newModel.sheet.cells
        let geometryChanged = model.geometry != newModel.geometry
        let themeChanged = model.theme != newModel.theme
        model = newModel
        // The shell rebuilds the render model from its own state, which knows nothing about a
        // flash in progress. The controller is the owner of that, so it wins.
        syncFlashIntoModel()
        if cellsChanged { blocks.update(cells: newModel.sheet.cells) }
        if themeChanged {
            scrollView.backgroundColor = NSColor(cgColor: newModel.theme.canvasBackground.cgColor)
                ?? .textBackgroundColor
        }
        if geometryChanged { resizeDocument() }
        needsLayout = true
        refreshAccessibilityTree()
        invalidateEverything()
    }

    /// Replaces just the selection, which is the hot path while dragging.
    public func setSelection(_ selection: GridSelection, emit: Bool = true) {
        guard model.selection != selection else { return }
        model.selection = selection
        invalidateEverything()
        postAccessibilitySelectionChange()
        if emit { onEvent?(.selectionChanged(selection)) }
    }

    /// Tints these cells and starts the decay. Stops on its own — see ``FlashController``.
    public func flash(_ refs: Set<CellRef>) {
        flashController.flash(refs)
    }

    // MARK: - Layout

    override public func layout() {
        super.layout()
        let theme = model.theme
        let lastRow = model.geometry.rows.index(atOffset: scrollOrigin.y + bounds.height)
        measuredHeaderWidth = headerRenderer.rowHeaderWidth(
            forLastRow: lastRow, theme: theme, zoom: model.geometry.zoom
        )
        let headerHeight = model.options.showsHeaders ? theme.headerHeight : 0
        let headerWidth = model.options.showsHeaders ? measuredHeaderWidth : 0
        let frozenWidth = model.geometry.frozenWidth
        let frozenHeight = model.geometry.frozenHeight
        // What the shell reserved: the chrome the grid bleeds under at the top, the floating pills
        // at the bottom. It is scroll range, never a mask — cells pass through it as you scroll.
        let reserved = model.options.contentInsets

        scrollView.frame = bounds
        scrollView.contentInsets = NSEdgeInsets(
            top: reserved.top + headerHeight + frozenHeight,
            left: reserved.left + headerWidth + frozenWidth,
            bottom: reserved.bottom,
            right: reserved.right
        )
        // Cancels the grid's *own* reservation and nothing else: the scrollers run the full length
        // of the grid's edges, as they did before, but the shell's reservation still stands — so
        // they stop below the chrome and above the floating pills instead of running behind them.
        scrollView.scrollerInsets = NSEdgeInsets(top: -headerHeight, left: -headerWidth, bottom: 0, right: 0)

        cornerView.isHidden = !model.options.showsHeaders
        columnHeaderView.isHidden = !model.options.showsHeaders
        rowHeaderView.isHidden = !model.options.showsHeaders
        cornerView.frame = CGRect(
            x: reserved.left, y: reserved.top, width: headerWidth, height: headerHeight
        )
        columnHeaderView.frame = CGRect(
            x: reserved.left + headerWidth,
            y: reserved.top,
            width: max(0, bounds.width - reserved.left - headerWidth),
            height: headerHeight
        )
        // Down to the bottom edge, not to the bottom inset: a row drawn under a floating pill is
        // still a row, and an unlabelled one would look like a rendering fault.
        rowHeaderView.frame = CGRect(
            x: reserved.left,
            y: reserved.top + headerHeight,
            width: headerWidth,
            height: max(0, bounds.height - reserved.top - headerHeight)
        )

        let bodyOrigin = CGPoint(x: reserved.left + headerWidth, y: reserved.top + headerHeight)
        let bodySize = CGSize(
            width: max(0, bounds.width - bodyOrigin.x), height: max(0, bounds.height - bodyOrigin.y)
        )
        frozenPaneViews[.corner]?.frame = CGRect(
            origin: bodyOrigin, size: CGSize(width: frozenWidth, height: frozenHeight)
        )
        frozenPaneViews[.top]?.frame = CGRect(
            x: bodyOrigin.x + frozenWidth, y: bodyOrigin.y,
            width: max(0, bodySize.width - frozenWidth), height: frozenHeight
        )
        frozenPaneViews[.left]?.frame = CGRect(
            x: bodyOrigin.x, y: bodyOrigin.y + frozenHeight,
            width: frozenWidth, height: max(0, bodySize.height - frozenHeight)
        )
        for (pane, view) in frozenPaneViews {
            view.isHidden = !model.geometry.activePanes.contains(pane)
        }
        frozenOverlay.frame = CGRect(origin: bodyOrigin, size: bodySize)
        frozenOverlay.isHidden = !model.geometry.hasFrozenPanes

        renderer.backingScale = Double(window?.backingScaleFactor ?? 2)
        headerRenderer.backingScale = renderer.backingScale
        resizeDocument()
        invalidateEverything()
    }

    private func resizeDocument() {
        let size = model.geometry.scrollableSize
        if documentView.frame.size != size {
            documentView.frame = CGRect(origin: .zero, size: size)
        }
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderer.backingScale = Double(window?.backingScaleFactor ?? 2)
        headerRenderer.backingScale = renderer.backingScale
        // Glyph rasterisation and hairline alignment both depend on the scale, so a drag between
        // a Retina and a non-Retina display has to re-shape, not just redraw.
        renderer.invalidateCaches()
        invalidateEverything()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            flashController.setTicker(DisplayLinkTicker(view: documentView))
        } else {
            flashController.setTicker(nil)
        }
    }

    // MARK: - Scrolling

    /// The document-space point at the top-left of the scrolling body.
    public var scrollOrigin: CGPoint {
        let bounds = scrollView.contentView.bounds
        let insets = scrollView.contentInsets
        return CGPoint(x: max(0, bounds.origin.x + insets.left), y: max(0, bounds.origin.y + insets.top))
    }

    /// The part of the host that is *only* scrolling cells — inside the headers, the frozen band
    /// and anything the shell reserved.
    ///
    /// Content is still drawn outside it: the whole point of a shell inset is that cells pass
    /// under the chrome and under the floating pills. This is the rectangle that decides how far a
    /// Page Down moves and what "bring this cell into view" has to clear, and neither of those may
    /// land a cell somewhere the user cannot read it.
    var bodyRect: CGRect {
        let insets = scrollView.contentInsets
        return CGRect(
            x: insets.left,
            y: insets.top,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
    }

    /// The size of the body pane — what a Page Down moves by.
    public var bodyViewportSize: CGSize { bodyRect.size }

    @objc private func scrollViewDidScroll() {
        columnHeaderView.needsDisplay = true
        rowHeaderView.needsDisplay = true
        for view in frozenPaneViews.values { view.needsDisplay = true }
        frozenOverlay.needsDisplay = true
        repositionEditor()
        refreshAccessibilityTree()
        emitVisibleRangeIfChanged()
    }

    /// Scrolls the smallest distance that brings `ref` fully into view.
    public func scroll(to ref: CellRef) {
        guard let origin = model.geometry.scrollOrigin(
            toReveal: ref,
            currentOrigin: scrollOrigin,
            viewportSize: bodyViewportSize
        ) else { return }
        scrollView.contentView.scroll(to: CGPoint(
            x: origin.x - scrollView.contentInsets.left,
            y: origin.y - scrollView.contentInsets.top
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The cells currently on screen, merges included.
    public var visibleRange: CellRange {
        let origin = model.geometry.sheetPoint(fromDocument: scrollOrigin)
        let rect = CGRect(origin: origin, size: bodyViewportSize)
        return model.merges.expanded(model.geometry.cellRange(inSheetRect: rect))
    }

    private func emitVisibleRangeIfChanged() {
        let range = visibleRange
        guard range != lastEmittedVisibleRange else { return }
        lastEmittedVisibleRange = range
        onEvent?(.visibleRangeChanged(range))
    }

    // MARK: - Invalidation

    private func invalidateEverything() {
        documentView.needsDisplay = true
        columnHeaderView.needsDisplay = true
        rowHeaderView.needsDisplay = true
        cornerView.needsDisplay = true
        frozenOverlay.needsDisplay = true
        for view in frozenPaneViews.values { view.needsDisplay = true }
    }

    /// Repaints only the cells in `range`, which is what keeps a decaying flash from costing a
    /// full-screen redraw sixty times a second.
    private func invalidate(_ range: CellRange?) {
        guard let range else {
            invalidateEverything()
            return
        }
        let sheetRect = model.geometry.sheetRect(of: range)
        let documentRect = model.geometry.documentRect(fromSheet: sheetRect)
        documentView.setNeedsDisplay(documentRect.insetBy(dx: -2, dy: -2))
        for (pane, view) in frozenPaneViews where !view.isHidden {
            let origin = paneSheetOrigin(pane)
            view.setNeedsDisplay(
                sheetRect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -2, dy: -2)
            )
        }
    }

    // MARK: - Pane coordinates

    /// The sheet-space point that sits at a pane view's own origin.
    func paneSheetOrigin(_ pane: GridPane) -> CGPoint {
        let geometry = model.geometry
        switch pane {
        case .corner: return .zero
        case .top: return CGPoint(x: geometry.frozenWidth + scrollOrigin.x, y: 0)
        case .left: return CGPoint(x: 0, y: geometry.frozenHeight + scrollOrigin.y)
        case .body: return geometry.sheetPoint(fromDocument: scrollOrigin)
        }
    }

    func sheetOrigin(for pane: GridPane, viewPoint: CGPoint) -> CGPoint {
        let base = paneSheetOrigin(pane)
        return CGPoint(x: base.x + viewPoint.x, y: base.y + viewPoint.y)
    }

    private func sheetPoint(_ point: CGPoint, in pane: GridPane) -> CGPoint {
        let base = paneSheetOrigin(pane)
        return CGPoint(x: base.x + point.x, y: base.y + point.y)
    }

    /// Header x in the column header's own coordinates → sheet x.
    func sheetX(fromColumnHeader x: Double) -> Double {
        x < model.geometry.frozenWidth ? x : x + scrollOrigin.x
    }

    /// Header y in the row header's own coordinates → sheet y.
    func sheetY(fromRowHeader y: Double) -> Double {
        y < model.geometry.frozenHeight ? y : y + scrollOrigin.y
    }

    // MARK: - Mouse

    func paneMouseDown(_ event: NSEvent, pane: GridPane, in view: NSView) {
        window?.makeFirstResponder(documentView)
        if editor.isEditing { editor.commit(advance: nil) }

        let point = view.convert(event.locationInWindow, from: nil)
        let sheet = sheetPoint(point, in: pane)
        let ref = model.merges.anchor(of: model.geometry.cellRef(atSheetPoint: sheet))

        if model.options.showsFillHandle, fillHandleRect()?.contains(sheet) == true {
            dragMode = .fillHandle(source: model.selection.activeRange)
            fillTarget = model.selection.activeRange
            return
        }

        if event.clickCount >= 2 {
            if let link = model.sheet.hyperlinks[ref] {
                onEvent?(.activateHyperlink(ref: ref, link: link))
            }
            beginEdit(at: ref, seed: nil)
            onEvent?(.doubleClicked(ref: ref))
            return
        }

        var selection = model.selection
        let span = model.merges.merge(containing: ref)
        if event.modifierFlags.contains(.shift) {
            selection.extend(to: ref, span: span)
        } else if event.modifierFlags.contains(.command) {
            selection.addRange(span ?? CellRange(ref), active: ref)
        } else {
            selection.select(ref, span: span)
        }
        dragMode = .selecting
        setSelection(selection)
    }

    func paneMouseDragged(_ event: NSEvent, pane: GridPane, in view: NSView) {
        let point = view.convert(event.locationInWindow, from: nil)
        let sheet = sheetPoint(point, in: pane)
        let ref = model.geometry.cellRef(atSheetPoint: sheet)

        switch dragMode {
        // A header drag is tracked by the header view that received the press — AppKit keeps
        // sending it there for the length of the drag — so it never reaches a pane.
        case .none, .headerSelecting:
            return
        case .selecting:
            var selection = model.selection
            selection.extend(to: ref, span: model.merges.merge(containing: ref))
            setSelection(selection, emit: false)
            startAutoscrollIfNeeded(event)
        case let .fillHandle(source):
            fillTarget = Self.fillTarget(from: source, to: ref)
            invalidateEverything()
            startAutoscrollIfNeeded(event)
        }
    }

    func paneMouseUp(_ event: NSEvent, pane: GridPane, in view: NSView) {
        stopAutoscroll()
        switch dragMode {
        case .none:
            break
        // `.selecting` and `.headerSelecting` both end the same way: one change for the whole
        // drag, after a run of silent `emit: false` updates.
        case .selecting, .headerSelecting:
            onEvent?(.selectionChanged(model.selection))
        case let .fillHandle(source):
            if let target = fillTarget, target != source {
                onEvent?(.fillHandleDragged(source: source, target: target))
            }
            fillTarget = nil
            invalidateEverything()
        }
        dragMode = .none
        _ = event
        _ = pane
        _ = view
    }

    func paneRightMouseDown(_ event: NSEvent, pane: GridPane, in view: NSView) {
        let point = view.convert(event.locationInWindow, from: nil)
        let ref = model.merges.anchor(of: model.geometry.cellRef(atSheetPoint: sheetPoint(point, in: pane)))
        if !model.selection.contains(ref) {
            var selection = model.selection
            selection.select(ref, span: model.merges.merge(containing: ref))
            setSelection(selection)
        }
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        onEvent?(.contextMenu(ref: ref, selection: model.selection, screenPoint: screenPoint))
    }

    /// The fill handle's hit rectangle in sheet space.
    private func fillHandleRect() -> CGRect? {
        guard model.options.showsFillHandle else { return nil }
        let box = model.geometry.sheetRect(of: model.selection.activeRange)
        let side = model.theme.fillHandleSize + 3
        return CGRect(x: box.maxX - side / 2, y: box.maxY - side / 2, width: side, height: side)
    }

    /// Excel fills along one axis at a time — whichever the drag went further in.
    static func fillTarget(from source: CellRange, to ref: CellRef) -> CellRange {
        let rowDistance = ref.row < source.start.row
            ? source.start.row - ref.row
            : max(0, ref.row - source.end.row)
        let columnDistance = ref.column < source.start.column
            ? source.start.column - ref.column
            : max(0, ref.column - source.end.column)

        if rowDistance >= columnDistance {
            let rows = min(source.start.row, ref.row) ... max(source.end.row, ref.row)
            return CellRange(rows: rows, columns: source.columns)
        }
        let columns = min(source.start.column, ref.column) ... max(source.end.column, ref.column)
        return CellRange(rows: source.rows, columns: columns)
    }

    /// Scrolls while a drag is held past the edge of the viewport.
    ///
    /// Hand-rolled rather than `NSView.autoscroll(with:)` because the selection has to keep
    /// extending while the pointer is stationary, and because a repeating timer that outlives the
    /// drag is the same battery bug as a display link that never stops — so it is created on
    /// demand and invalidated on mouse-up, always.
    private func startAutoscrollIfNeeded(_ event: NSEvent) {
        lastDragWindowPoint = event.locationInWindow
        guard autoscrollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollStep() }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        autoscrollTimer = timer
    }

    /// Whether a drag is currently holding the autoscroll timer open.
    ///
    /// Internal for the tests that assert the timer is always given back on mouse-up: a repeating
    /// timer that outlives its drag is the battery bug this whole mechanism was written to avoid.
    var isAutoscrolling: Bool { autoscrollTimer != nil }

    /// One tick. Internal so a test can pump it deterministically rather than waiting on a real
    /// 30Hz timer — the drag state it reads is the same state the timer would find.
    func autoscrollStep() {
        if case .none = dragMode {
            stopAutoscroll()
            return
        }
        let local = convert(lastDragWindowPoint, from: nil)
        let insets = scrollView.contentInsets
        let body = bodyRect
        let edge = 24.0
        var delta = CGPoint.zero
        if local.x < body.minX + edge { delta.x = local.x - (body.minX + edge) }
        if local.x > body.maxX - edge { delta.x = local.x - (body.maxX - edge) }
        if local.y < body.minY + edge { delta.y = local.y - (body.minY + edge) }
        if local.y > body.maxY - edge { delta.y = local.y - (body.maxY - edge) }
        // A header drag runs along one axis only. The pointer spends the whole drag *outside* the
        // body on the other one — above it in the column strip, left of it in the row strip — so
        // leaving the cross-axis delta in would scroll the sheet away under a drag that never
        // moved that way.
        if case let .headerSelecting(axis) = dragMode {
            if axis == .column { delta.y = 0 } else { delta.x = 0 }
        }
        guard delta.x != 0 || delta.y != 0 else { return }

        let origin = scrollOrigin
        let target = CGPoint(
            x: max(0, origin.x + delta.x), y: max(0, origin.y + delta.y)
        )
        scrollView.contentView.scroll(to: CGPoint(x: target.x - insets.left, y: target.y - insets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Keep the selection following the pointer, which is what "drag-select with autoscroll"
        // means to the person doing it.
        let sheet = model.geometry.sheetPoint(
            fromDocument: CGPoint(x: target.x + local.x - body.minX, y: target.y + local.y - body.minY)
        )
        let ref = model.geometry.cellRef(atSheetPoint: sheet)
        switch dragMode {
        case .selecting:
            var selection = model.selection
            selection.extend(to: ref, span: model.merges.merge(containing: ref))
            setSelection(selection, emit: false)
        case let .fillHandle(source):
            fillTarget = Self.fillTarget(from: source, to: ref)
            invalidateEverything()
        case let .headerSelecting(axis):
            // Read back off the header view *after* the scroll landed, so a stationary pointer
            // keeps taking in new columns — the whole point of holding a drag at the edge.
            setSelection(
                Self.headerSelection(
                    from: model.selection,
                    axis: axis,
                    index: headerIndex(axis: axis, atWindowPoint: lastDragWindowPoint),
                    mode: .extend
                ),
                emit: false
            )
        case .none:
            break
        }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    // MARK: - Header interaction

    func columnDivider(nearSheetX x: Double) -> Int? {
        let columns = model.geometry.columns
        let slop = model.theme.resizeHitSlop
        let index = columns.index(atOffset: x)
        if abs(columns.offset(ofIndex: index) - x) <= slop, index > 0 { return index - 1 }
        if abs(columns.offset(ofIndex: index + 1) - x) <= slop { return index }
        return nil
    }

    func rowDivider(nearSheetY y: Double) -> Int? {
        let rows = model.geometry.rows
        let slop = model.theme.resizeHitSlop
        let index = rows.index(atOffset: y)
        if abs(rows.offset(ofIndex: index) - y) <= slop, index > 0 { return index - 1 }
        if abs(rows.offset(ofIndex: index + 1) - y) <= slop { return index }
        return nil
    }

    func columnDividerRects(in rect: CGRect) -> [CGRect] {
        let columns = model.geometry.columns
        let slop = model.theme.resizeHitSlop
        let first = columns.index(atOffset: sheetX(fromColumnHeader: rect.minX))
        let last = columns.index(atOffset: sheetX(fromColumnHeader: rect.maxX))
        guard first <= last else { return [] }
        return (first ... last).compactMap { column in
            let sheet = columns.offset(ofIndex: column + 1)
            let x = sheet < model.geometry.frozenWidth ? sheet : sheet - scrollOrigin.x
            return CGRect(x: x - slop, y: rect.minY, width: slop * 2, height: rect.height)
        }
    }

    func rowDividerRects(in rect: CGRect) -> [CGRect] {
        let rows = model.geometry.rows
        let slop = model.theme.resizeHitSlop
        let first = rows.index(atOffset: sheetY(fromRowHeader: rect.minY))
        let last = rows.index(atOffset: sheetY(fromRowHeader: rect.maxY))
        guard first <= last else { return [] }
        return (first ... last).compactMap { row in
            let sheet = rows.offset(ofIndex: row + 1)
            let y = sheet < model.geometry.frozenHeight ? sheet : sheet - scrollOrigin.y
            return CGRect(x: rect.minX, y: y - slop, width: rect.width, height: slop * 2)
        }
    }

    /// The column or row under a point in **window** coordinates.
    ///
    /// Read back through the header view's own coordinate space rather than off `bodyRect`,
    /// because that is the mapping ``sheetX(fromColumnHeader:)`` was written against — frozen
    /// band and all. The drag and the autoscroll that chases it therefore cannot disagree about
    /// which column the pointer is over, which is the class of bug that makes a selection
    /// "jump a column" the moment it starts scrolling.
    func headerIndex(axis: HeaderAxis, atWindowPoint point: CGPoint) -> Int {
        switch axis {
        case .column:
            let x = columnHeaderView.convert(point, from: nil).x
            return model.geometry.columns.index(atOffset: sheetX(fromColumnHeader: x))
        case .row:
            let y = rowHeaderView.convert(point, from: nil).y
            return model.geometry.rows.index(atOffset: sheetY(fromRowHeader: y))
        }
    }

    /// Excel's header-selection rules, as a pure function of the selection they start from.
    ///
    /// Every way of selecting a header goes through here — plain click, shift-click, `⌘`-click
    /// and each step of a drag — so the click path and the drag path cannot drift apart. It is
    /// `static` so the rules can be asserted without a window.
    static func headerSelection(
        from current: GridSelection,
        axis: HeaderAxis,
        index: Int,
        mode: HeaderSelectMode
    ) -> GridSelection {
        let target = axis.clamped(index)
        var selection = current
        switch mode {
        case .replace:
            selection.select(axis.entireRange(target), active: axis.head(target))
        case .add:
            selection.addRange(axis.entireRange(target), active: axis.head(target))
        case .extend:
            // Deliberately *not* `GridSelection.extend(to:)`. That pivots on the anchor cell, so
            // after clicking body cell B5 a shift-click on column D's header would take
            // `B5:D1048576` — a block starting at row 5 — instead of the whole of B:D that Excel
            // takes. The band is the axis's own business, and the cross axis is always the full
            // sheet.
            let range = axis.band(from: axis.index(of: current.anchor), to: target)
            var ranges = current.ranges
            ranges[current.activeRangeIndex] = range
            // The caret stays where it was while the band grows around it — drag C→F and the
            // active cell is still C1 — and only moves if the band left it behind.
            selection = GridSelection(
                ranges: ranges,
                active: range.contains(current.active) ? current.active : range.start,
                anchor: current.anchor,
                activeRangeIndex: current.activeRangeIndex
            )
        }
        return selection
    }

    func selectEntireColumn(_ column: Int, extending: Bool, adding: Bool) {
        setSelection(Self.headerSelection(
            from: model.selection, axis: .column, index: column,
            mode: HeaderSelectMode(extending: extending, adding: adding)
        ))
    }

    func selectEntireRow(_ row: Int, extending: Bool, adding: Bool) {
        setSelection(Self.headerSelection(
            from: model.selection, axis: .row, index: row,
            mode: HeaderSelectMode(extending: extending, adding: adding)
        ))
    }

    func selectAll() {
        beginHeaderInteraction()
        var selection = model.selection
        selection.select(CellRange.entireSheet, active: .origin)
        setSelection(selection)
    }

    /// A header click moves the focus as well as the caret, exactly as a body click does: the
    /// grid has to be first responder for the arrow keys that follow, and an edit in progress has
    /// to land somewhere rather than be abandoned in an editor that is no longer over its cell.
    private func beginHeaderInteraction() {
        window?.makeFirstResponder(documentView)
        if editor.isEditing { editor.commit(advance: nil) }
    }

    /// Mouse-down on a header body. Selects immediately; a drag then extends what it selected.
    func beginHeaderSelection(axis: HeaderAxis, index: Int, extending: Bool, adding: Bool) {
        beginHeaderInteraction()
        setSelection(Self.headerSelection(
            from: model.selection, axis: axis, index: index,
            mode: HeaderSelectMode(extending: extending, adding: adding)
        ))
        // `select` and `addRange` both leave the anchor on the header just clicked, and `extend`
        // leaves it alone, so in all three cases the drag that follows pivots on the right one.
        dragMode = .headerSelecting(axis: axis)
    }

    /// One step of a header drag: the band from the anchor to wherever the pointer is now,
    /// including when it has come back past the anchor and reversed the band.
    func extendHeaderSelection(_ event: NSEvent, axis: HeaderAxis) {
        guard case .headerSelecting = dragMode else { return }
        let index = headerIndex(axis: axis, atWindowPoint: event.locationInWindow)
        setSelection(
            Self.headerSelection(from: model.selection, axis: axis, index: index, mode: .extend),
            emit: false
        )
        startAutoscrollIfNeeded(event)
    }

    /// Mouse-up on a header. Emits the one selection change the whole drag amounts to.
    func endHeaderSelection() {
        stopAutoscroll()
        if case .headerSelecting = dragMode { onEvent?(.selectionChanged(model.selection)) }
        dragMode = .none
    }

    func previewColumnResize(_ column: Int, width: Double) {
        var sheet = model.sheet
        sheet.columnWidths.setValue(max(0, width / model.geometry.zoom), in: column ... column)
        model.sheet = sheet
        model.geometry = GridGeometry(sheet: sheet, zoom: model.geometry.zoom)
        resizeDocument()
        invalidateEverything()
    }

    func commitColumnResize(_ column: Int, width: Double) {
        let columns = model.selection.coversEntireColumn(column)
            ? model.selection.boundingRange.columns
            : column ... column
        onEvent?(.columnsResized(columns: columns, width: width / model.geometry.zoom))
    }

    func previewRowResize(_ row: Int, height: Double) {
        var sheet = model.sheet
        sheet.rowHeights.setValue(max(0, height / model.geometry.zoom), in: row ... row)
        model.sheet = sheet
        model.geometry = GridGeometry(sheet: sheet, zoom: model.geometry.zoom)
        resizeDocument()
        invalidateEverything()
    }

    func commitRowResize(_ row: Int, height: Double) {
        let rows = model.selection.coversEntireRow(row)
            ? model.selection.boundingRange.rows
            : row ... row
        onEvent?(.rowsResized(rows: rows, height: height / model.geometry.zoom))
    }

    func autoFitColumn(_ column: Int) {
        let columns = model.selection.coversEntireColumn(column)
            ? model.selection.boundingRange.columns
            : column ... column
        let suggested = GridAutoFit.widths(
            forColumns: columns, model: model, cache: renderer.textCache, rows: visibleRange.rows
        )
        onEvent?(.autoFitColumns(columns: columns, suggested: suggested))
    }

    func autoFitRow(_ row: Int) {
        let rows = model.selection.coversEntireRow(row) ? model.selection.boundingRange.rows : row ... row
        var suggested: [Int: Double] = [:]
        for index in rows {
            suggested[index] = GridAutoFit.height(
                ofRow: index, model: model, cache: renderer.textCache, wrapped: renderer.wrappedCache
            )
        }
        onEvent?(.autoFitRows(rows: rows, suggested: suggested))
    }

    // MARK: - Keyboard

    func focusChanged(_ focused: Bool) {
        model.isFocused = focused
        invalidateEverything()
    }

    private func focusDocument() {
        window?.makeFirstResponder(documentView)
    }

    /// Returns `true` when the grid consumed the key.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard !editor.isEditing else { return false }
        let flags = event.modifierFlags
        let extending = flags.contains(.shift)
        let command = flags.contains(.command)

        if let motion = Self.motion(for: event.keyCode, command: command) {
            let navigator = GridNavigator(
                geometry: model.geometry, merges: model.merges, blocks: blocks, usedRange: model.sheet.usedRange
            )
            let updated = navigator.apply(
                motion, extending: extending, to: model.selection, viewport: bodyViewportSize
            )
            setSelection(updated)
            scroll(to: updated.active)
            return true
        }

        switch event.keyCode {
        case 48: // Tab
            advance(extending ? .backward : .forward)
            return true
        case 36, 76: // Return / Enter
            advance(extending ? .up : .down)
            return true
        case 51, 117: // Delete, forward delete
            onEvent?(.clearContents(model.selection.ranges))
            return true
        case 53: // Escape
            model.selection.collapseToActiveRange()
            invalidateEverything()
            return true
        case 120: // F2
            beginEdit(at: model.selection.active, seed: nil)
            return true
        default:
            break
        }

        // Type-to-edit: any printable character with no command key replaces the cell.
        if !command, !flags.contains(.control), !flags.contains(.function),
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            beginEdit(at: model.selection.active, seed: characters)
            return true
        }
        return false
    }

    static func motion(for keyCode: UInt16, command: Bool) -> GridMotion? {
        switch keyCode {
        case 126: command ? .blockUp : .up
        case 125: command ? .blockDown : .down
        case 123: command ? .blockLeft : .left
        case 124: command ? .blockRight : .right
        case 115: command ? .sheetStart : .rowStart
        case 119: command ? .sheetEnd : .rowEnd
        case 116: .pageUp
        case 121: .pageDown
        default: nil
        }
    }

    private func advance(_ direction: AdvanceDirection) {
        let navigator = GridNavigator(
            geometry: model.geometry, merges: model.merges, blocks: blocks, usedRange: model.sheet.usedRange
        )
        let updated = navigator.advance(direction, in: model.selection)
        setSelection(updated)
        scroll(to: updated.active)
    }

    // MARK: - Editing

    /// Opens the in-cell editor, unless the cell's value belongs to somebody else.
    public func beginEdit(at ref: CellRef, seed: String?) {
        guard model.options.isEditable else { return }
        let anchor = model.merges.anchor(of: ref)
        // **Refused, not silently ignored.** A cell whose value belongs to a spill anchor would
        // be overwritten by the next recalculation, and Excel refuses the same edit. A grid that
        // just swallowed the keystroke would be indistinguishable from a broken one, so the
        // refusal is audible, and the reason names the cell that owns this one.
        if let refusal = model.editRefusal(at: anchor) {
            scroll(to: anchor)
            NSSound.beep()
            onEditRefused?(anchor, refusal)
            return
        }
        scroll(to: anchor)
        let cell = model.sheet.cells[anchor]
        let styleID = model.effectiveStyleID(at: anchor, cell: cell)
        let style = model.styles[styleID]
        let text = seed ?? renderer.displayFormatter.editText(of: cell)
        let span = model.merges.merge(containing: anchor) ?? CellRange(anchor)

        editor.begin(
            at: anchor,
            rect: editorRect(for: span),
            text: text,
            theme: model.theme,
            zoom: model.geometry.zoom,
            alignment: style.alignment.horizontal == .general
                ? (cell?.value.number != nil ? .right : .left)
                : style.alignment.horizontal,
            maximumSize: bodyViewportSize
        )
        onEvent?(.beginEdit(ref: anchor, seed: seed))
    }

    private func editorRect(for span: CellRange) -> CGRect {
        let sheetRect = model.geometry.sheetRect(of: span)
        let insets = scrollView.contentInsets
        let origin = model.geometry.sheetPoint(fromDocument: scrollOrigin)
        return CGRect(
            x: sheetRect.minX - origin.x + insets.left,
            y: sheetRect.minY - origin.y + insets.top,
            width: sheetRect.width,
            height: sheetRect.height
        )
    }

    private func repositionEditor() {
        guard let ref = editor.editingRef else { return }
        let span = model.merges.merge(containing: ref) ?? CellRange(ref)
        editor.frame = CGRect(origin: editorRect(for: span).origin, size: editor.frame.size)
        editor.resize()
    }

    private func finishEdit(ref: CellRef, text: String, advance direction: AdvanceDirection?) {
        onEvent?(.commitEdit(ref: ref, text: text, advance: direction))
        focusDocument()
        if let direction { advance(direction) }
    }

    /// The preview rectangle while the fill handle is being dragged, for tests and for the shell.
    public var fillPreview: CellRange? { fillTarget }

    /// The view that should hold keyboard focus for the grid.
    public var firstResponderTarget: NSView { documentView }

    /// The grid's scroll view, so the shell can observe scrolling or restyle the scrollers.
    /// Everything else about the hierarchy is private on purpose.
    public var contentScrollView: NSScrollView { scrollView }


}
