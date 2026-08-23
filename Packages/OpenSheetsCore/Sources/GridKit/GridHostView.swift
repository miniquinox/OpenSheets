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
/// The scroll view fills the host. Its `contentInsets` reserve the header strip **and** the
/// frozen band, so the document view scrolls underneath both without either needing to move.
/// Headers and frozen panes are `addFloatingSubview(_:for:)` children with fixed frames: they do
/// not slide, they redraw with a different scroll origin. Fixed frames make the layout
/// deterministic, which is worth more than saving a redraw.
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
            scrollView.addFloatingSubview(view, for: .vertical)
        }
        scrollView.addFloatingSubview(frozenOverlay, for: .vertical)
        // Headers float on the axis they must not move along; their frames are set explicitly on
        // every layout pass, so AppKit's own positioning never gets a chance to disagree.
        scrollView.addFloatingSubview(columnHeaderView, for: .vertical)
        scrollView.addFloatingSubview(rowHeaderView, for: .horizontal)
        scrollView.addFloatingSubview(cornerView, for: .vertical)
        scrollView.addFloatingSubview(editor, for: .vertical)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        flashController.setTicker(DisplayLinkTicker(view: documentView))
        flashController.onInvalidate = { [weak self] range in
            self?.invalidate(range)
        }
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

        scrollView.frame = bounds
        scrollView.contentInsets = NSEdgeInsets(
            top: headerHeight + frozenHeight, left: headerWidth + frozenWidth, bottom: 0, right: 0
        )
        scrollView.scrollerInsets = NSEdgeInsets(top: -headerHeight, left: -headerWidth, bottom: 0, right: 0)

        cornerView.isHidden = !model.options.showsHeaders
        columnHeaderView.isHidden = !model.options.showsHeaders
        rowHeaderView.isHidden = !model.options.showsHeaders
        cornerView.frame = CGRect(x: 0, y: 0, width: headerWidth, height: headerHeight)
        columnHeaderView.frame = CGRect(
            x: headerWidth, y: 0, width: max(0, bounds.width - headerWidth), height: headerHeight
        )
        rowHeaderView.frame = CGRect(
            x: 0, y: headerHeight, width: headerWidth, height: max(0, bounds.height - headerHeight)
        )

        let bodyOrigin = CGPoint(x: headerWidth, y: headerHeight)
        let bodySize = CGSize(
            width: max(0, bounds.width - headerWidth), height: max(0, bounds.height - headerHeight)
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

    /// The size of the body pane — what a Page Down moves by.
    public var bodyViewportSize: CGSize {
        let insets = scrollView.contentInsets
        return CGSize(
            width: max(0, bounds.width - insets.left),
            height: max(0, bounds.height - insets.top)
        )
    }

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
        case .none:
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
        case .selecting:
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

    private func autoscrollStep() {
        if case .none = dragMode {
            stopAutoscroll()
            return
        }
        let local = convert(lastDragWindowPoint, from: nil)
        let insets = scrollView.contentInsets
        let body = CGRect(
            x: insets.left, y: insets.top,
            width: max(0, bounds.width - insets.left), height: max(0, bounds.height - insets.top)
        )
        let edge = 24.0
        var delta = CGPoint.zero
        if local.x < body.minX + edge { delta.x = local.x - (body.minX + edge) }
        if local.x > body.maxX - edge { delta.x = local.x - (body.maxX - edge) }
        if local.y < body.minY + edge { delta.y = local.y - (body.minY + edge) }
        if local.y > body.maxY - edge { delta.y = local.y - (body.maxY - edge) }
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

    func selectEntireColumn(_ column: Int, extending: Bool, adding: Bool) {
        let range = CellRange.entireColumn(column)
        var selection = model.selection
        if extending {
            selection.extend(to: CellRef(row: Limits.maxRow, column: column))
        } else if adding {
            selection.addRange(range, active: CellRef(row: 0, column: column))
        } else {
            selection.select(range, active: CellRef(row: 0, column: column))
        }
        setSelection(selection)
    }

    func selectEntireRow(_ row: Int, extending: Bool, adding: Bool) {
        let range = CellRange.entireRow(row)
        var selection = model.selection
        if extending {
            selection.extend(to: CellRef(row: row, column: Limits.maxColumn))
        } else if adding {
            selection.addRange(range, active: CellRef(row: row, column: 0))
        } else {
            selection.select(range, active: CellRef(row: row, column: 0))
        }
        setSelection(selection)
    }

    func selectAll() {
        var selection = model.selection
        selection.select(CellRange.entireSheet, active: .origin)
        setSelection(selection)
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

    /// Opens the in-cell editor.
    public func beginEdit(at ref: CellRef, seed: String?) {
        guard model.options.isEditable else { return }
        let anchor = model.merges.anchor(of: ref)
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
