import AppKit
import Foundation
import SheetModel

/// The scrolling quadrant, and the scroll view's document view.
///
/// Flipped, because sheet space is: row 0 at the top, y growing down. Un-flipping here would mean
/// every rectangle in the renderer carried a subtraction, and one of them would eventually be
/// wrong.
@MainActor
final class GridDocumentView: NSView {
    weak var host: GridHostView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The grid paints every pixel it owns, so AppKit can skip drawing what is behind it.
    override var isOpaque: Bool { true }
    /// `draw(_:)` is a full repaint of the dirty rect; layer-backed incremental drawing would
    /// buy nothing and cost a full-size backing store for a 25-million-point-tall view.
    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        GridInstrumentation.count(GridInstrumentation.frames)
        host.renderer.draw(
            .body,
            into: context,
            viewRect: dirtyRect,
            sheetOrigin: host.model.geometry.sheetPoint(fromDocument: dirtyRect.origin),
            model: host.model
        )
    }

    /// Overdraws roughly one screen in each scroll direction.
    ///
    /// A fling reveals new rows faster than a synchronous `draw(_:)` can service them; preparing
    /// a screenful ahead is what turns "blank band at the leading edge" into "already painted".
    /// More than a screenful is wasted work in the frame budget, so this is deliberately modest.
    override func prepareContent(in rect: NSRect) {
        let margin = (host?.model.options.overdrawScreens ?? 1) * (enclosingScrollView?
            .contentView.bounds.height ?? rect.height)
        super.prepareContent(in: rect.insetBy(dx: 0, dy: -margin))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        host?.paneMouseDown(event, pane: .body, in: self)
    }

    override func mouseDragged(with event: NSEvent) {
        host?.paneMouseDragged(event, pane: .body, in: self)
    }

    override func mouseUp(with event: NSEvent) {
        host?.paneMouseUp(event, pane: .body, in: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        host?.paneRightMouseDown(event, pane: .body, in: self)
    }

    override func keyDown(with event: NSEvent) {
        guard host?.handleKeyDown(event) != true else { return }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        host?.focusChanged(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        host?.focusChanged(false)
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

/// A frozen quadrant: the corner, the top band, or the left band.
///
/// Each is an independent view with its own clip, which is what "up to four quadrants,
/// independently clipped" means in practice — a wide cell in the frozen band cannot paint across
/// the divider, because it is drawing into a different view.
@MainActor
final class GridPaneView: NSView {
    let pane: GridPane
    weak var host: GridHostView?

    init(pane: GridPane) {
        self.pane = pane
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        host.renderer.draw(
            pane,
            into: context,
            viewRect: dirtyRect,
            sheetOrigin: host.sheetOrigin(for: pane, viewPoint: dirtyRect.origin),
            model: host.model
        )
    }

    override func mouseDown(with event: NSEvent) { host?.paneMouseDown(event, pane: pane, in: self) }
    override func mouseDragged(with event: NSEvent) { host?.paneMouseDragged(event, pane: pane, in: self) }
    override func mouseUp(with event: NSEvent) { host?.paneMouseUp(event, pane: pane, in: self) }
    override func rightMouseDown(with event: NSEvent) { host?.paneRightMouseDown(event, pane: pane, in: self) }
}

/// The frozen-pane dividers, drawn above every pane so the shadow falls on the scrolling side.
///
/// Transparent to the mouse: it exists to be looked at, not clicked.
@MainActor
final class GridFrozenOverlayView: NSView {
    weak var host: GridHostView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        host.headerRenderer.drawFrozenDividers(into: context, viewRect: bounds, model: host.model)
        _ = dirtyRect
    }
}

/// The column letters.
@MainActor
final class GridColumnHeaderView: NSView {
    weak var host: GridHostView?
    /// Non-nil only while a *divider* is being dragged. A drag that began anywhere else on the
    /// strip is a selection, and lives in the host so it can share the body's autoscroll.
    private var resizeDrag: HeaderDrag?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        host.headerRenderer.drawColumnHeader(
            into: context, viewRect: bounds, scrollOrigin: host.scrollOrigin, model: host.model
        )
        _ = dirtyRect
    }

    /// Which it is — a resize or a selection — is decided once, here, by where the press landed
    /// relative to the nearest divider. `GridTheme.resizeHitSlop` is the few points either side
    /// that count as "on" it; everything else is the header body, and drags a selection.
    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        let sheetX = host.sheetX(fromColumnHeader: point.x)
        if let divider = host.columnDivider(nearSheetX: sheetX) {
            if event.clickCount >= 2 {
                host.autoFitColumn(divider)
                return
            }
            resizeDrag = HeaderDrag(
                index: divider,
                startLocation: point.x,
                startSize: host.model.geometry.columns.size(ofIndex: divider)
            )
            return
        }
        host.beginHeaderSelection(
            axis: .column,
            index: host.headerIndex(axis: .column, atWindowPoint: event.locationInWindow),
            extending: event.modifierFlags.contains(.shift),
            adding: event.modifierFlags.contains(.command)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host else { return }
        if let state = resizeDrag {
            let delta = convert(event.locationInWindow, from: nil).x - state.startLocation
            host.previewColumnResize(state.index, width: max(0, state.startSize + delta))
            return
        }
        host.extendHeaderSelection(event, axis: .column)
    }

    override func mouseUp(with event: NSEvent) {
        guard let host else { return }
        guard let state = resizeDrag else {
            host.endHeaderSelection()
            return
        }
        resizeDrag = nil
        let point = convert(event.locationInWindow, from: nil)
        host.commitColumnResize(state.index, width: max(0, state.startSize + point.x - state.startLocation))
    }

    override func resetCursorRects() {
        guard let host else { return }
        addCursorRect(bounds, cursor: .arrow)
        for rect in host.columnDividerRects(in: bounds) {
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }
}

/// The row numbers.
@MainActor
final class GridRowHeaderView: NSView {
    weak var host: GridHostView?
    /// See ``GridColumnHeaderView/resizeDrag``.
    private var resizeDrag: HeaderDrag?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        host.headerRenderer.drawRowHeader(
            into: context, viewRect: bounds, scrollOrigin: host.scrollOrigin, model: host.model
        )
        _ = dirtyRect
    }

    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        let sheetY = host.sheetY(fromRowHeader: point.y)
        if let divider = host.rowDivider(nearSheetY: sheetY) {
            if event.clickCount >= 2 {
                host.autoFitRow(divider)
                return
            }
            resizeDrag = HeaderDrag(
                index: divider,
                startLocation: point.y,
                startSize: host.model.geometry.rows.size(ofIndex: divider)
            )
            return
        }
        host.beginHeaderSelection(
            axis: .row,
            index: host.headerIndex(axis: .row, atWindowPoint: event.locationInWindow),
            extending: event.modifierFlags.contains(.shift),
            adding: event.modifierFlags.contains(.command)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host else { return }
        if let state = resizeDrag {
            let delta = convert(event.locationInWindow, from: nil).y - state.startLocation
            host.previewRowResize(state.index, height: max(0, state.startSize + delta))
            return
        }
        host.extendHeaderSelection(event, axis: .row)
    }

    override func mouseUp(with event: NSEvent) {
        guard let host else { return }
        guard let state = resizeDrag else {
            host.endHeaderSelection()
            return
        }
        resizeDrag = nil
        let point = convert(event.locationInWindow, from: nil)
        host.commitRowResize(state.index, height: max(0, state.startSize + point.y - state.startLocation))
    }

    override func resetCursorRects() {
        guard let host else { return }
        addCursorRect(bounds, cursor: .arrow)
        for rect in host.rowDividerRects(in: bounds) {
            addCursorRect(rect, cursor: .resizeUpDown)
        }
    }
}

/// The square where the headers meet. Clicking it selects the sheet.
@MainActor
final class GridCornerView: NSView {
    weak var host: GridHostView?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        host.headerRenderer.drawCorner(into: context, viewRect: bounds, model: host.model)
        _ = dirtyRect
    }

    override func mouseDown(with event: NSEvent) {
        host?.selectAll()
        _ = event
    }
}

/// A header divider being dragged.
struct HeaderDrag {
    var index: Int
    var startLocation: Double
    var startSize: Double
}

/// Which header a click or a drag is on.
///
/// The column strip and the row strip are mirror images of each other, so every selection rule is
/// written once and asked which way round it runs. Writing them twice is how the two ended up
/// with different behaviour in every spreadsheet that has ever had this bug.
enum HeaderAxis: Sendable, Hashable {
    case column
    case row

    /// The whole column, or the whole row.
    func entireRange(_ index: Int) -> CellRange {
        self == .column ? .entireColumn(index) : .entireRow(index)
    }

    /// Where the caret lands: the top of a column, the start of a row.
    func head(_ index: Int) -> CellRef {
        self == .column ? CellRef(row: 0, column: index) : CellRef(row: index, column: 0)
    }

    /// This axis's component of a reference — a column index, or a row index.
    func index(of ref: CellRef) -> Int {
        self == .column ? ref.column : ref.row
    }

    /// Every column between two indices at full height, or every row at full width. Inclusive of
    /// both ends and indifferent to their order, which is what makes a drag that reverses back
    /// past its anchor simply produce the band the other way round.
    func band(from first: Int, to second: Int) -> CellRange {
        let span = Swift.min(first, second) ... Swift.max(first, second)
        return self == .column
            ? CellRange(rows: 0 ... Limits.maxRow, columns: span)
            : CellRange(rows: span, columns: 0 ... Limits.maxColumn)
    }

    /// An index pulled back onto the sheet.
    func clamped(_ index: Int) -> Int {
        Swift.min(Swift.max(0, index), self == .column ? Limits.maxColumn : Limits.maxRow)
    }
}

/// What a header click does to the selection already there — the modifier keys, named.
enum HeaderSelectMode: Sendable, Hashable {
    /// Plain click: this column or row, and nothing else.
    case replace
    /// Shift: the band from the anchor to here.
    case extend
    /// `⌘`: this column or row *as well*, disjoint from what was already selected.
    case add

    init(extending: Bool, adding: Bool) {
        if extending {
            self = .extend
        } else if adding {
            self = .add
        } else {
            self = .replace
        }
    }
}
