import AppKit
import SheetModel
import Testing
@testable import GridKit

/// Selecting whole columns and rows from the headers.
///
/// **Driven through the real views.** Every test here builds an `NSEvent` and hands it to
/// `GridColumnHeaderView.mouseDown(with:)` and friends, in a real `NSWindow`, because the defect
/// this suite exists for lived entirely in those overrides: `mouseDragged` handled a resize and
/// returned, so a drag that started on the header *body* did nothing at all. A test that called
/// `selectEntireColumn` directly passed throughout — and did, for the whole of A4's wave.
@Suite("Header selection")
@MainActor
struct HeaderSelectionTests {
    // MARK: - The rules, on their own

    @Test("A plain header click takes the whole column, and the caret goes to its top")
    func plainClick() {
        let selection = GridHostView.headerSelection(
            from: GridSelection(active: CellRef(row: 7, column: 9)),
            axis: .column, index: 2, mode: .replace
        )
        #expect(selection.ranges == [CellRange.entireColumn(2)])
        #expect(selection.active == CellRef(row: 0, column: 2))
        #expect(selection.anchor == CellRef(row: 0, column: 2))
    }

    /// The band is the axis's own business: the cross axis is always the full sheet, however the
    /// anchor came to be. Pivoting on the anchor *cell* instead — which is what
    /// `GridSelection.extend(to:)` does — would take `B5:D1048576` here, a block starting five
    /// rows down, rather than the whole of B:D that Excel takes.
    @Test("Shift-clicking a column header takes whole columns even when the anchor is a body cell")
    func shiftClickFromABodyCell() {
        var body = GridSelection()
        body.select(CellRef(row: 4, column: 1))
        let selection = GridHostView.headerSelection(from: body, axis: .column, index: 3, mode: .extend)

        #expect(selection.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 1 ... 3)])
        for column in 1 ... 3 { #expect(selection.coversEntireColumn(column)) }
        #expect(selection.anchor == CellRef(row: 4, column: 1), "the anchor is the pivot; it must not move")
        #expect(selection.active == CellRef(row: 4, column: 1), "the caret stays inside the band it grew")
    }

    @Test("Extending backwards past the anchor reverses the band rather than emptying it")
    func extendBackwards() {
        let start = GridHostView.headerSelection(
            from: GridSelection(), axis: .column, index: 4, mode: .replace
        )
        let forward = GridHostView.headerSelection(from: start, axis: .column, index: 7, mode: .extend)
        #expect(forward.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 4 ... 7)])

        // Same anchor, pointer now to the *left* of it.
        let backward = GridHostView.headerSelection(from: forward, axis: .column, index: 1, mode: .extend)
        #expect(backward.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 1 ... 4)])
        #expect(backward.active == CellRef(row: 0, column: 4), "the caret is still on the anchor column")
    }

    @Test("Rows are the mirror image of columns")
    func rowRules() {
        let start = GridHostView.headerSelection(from: GridSelection(), axis: .row, index: 2, mode: .replace)
        #expect(start.ranges == [CellRange.entireRow(2)])
        let band = GridHostView.headerSelection(from: start, axis: .row, index: 5, mode: .extend)
        #expect(band.ranges == [CellRange(rows: 2 ... 5, columns: 0 ... Limits.maxColumn)])
        for row in 2 ... 5 { #expect(band.coversEntireRow(row)) }
    }

    /// `⌘` moves the anchor onto the range it just added, so the drag that follows extends *that*
    /// one and leaves the earlier ranges alone.
    @Test("⌘-click adds a disjoint column and re-anchors onto it")
    func commandClickReanchors() {
        let first = GridHostView.headerSelection(from: GridSelection(), axis: .column, index: 1, mode: .replace)
        let added = GridHostView.headerSelection(from: first, axis: .column, index: 5, mode: .add)
        #expect(added.ranges == [.entireColumn(1), .entireColumn(5)])
        #expect(added.anchor == CellRef(row: 0, column: 5))

        let dragged = GridHostView.headerSelection(from: added, axis: .column, index: 7, mode: .extend)
        #expect(dragged.ranges == [.entireColumn(1), CellRange(rows: 0 ... Limits.maxRow, columns: 5 ... 7)])
    }

    @Test("An index off the end of the sheet is pulled back onto it")
    func clamping() {
        let selection = GridHostView.headerSelection(
            from: GridSelection(), axis: .column, index: Limits.maxColumn + 500, mode: .replace
        )
        #expect(selection.ranges == [CellRange.entireColumn(Limits.maxColumn)])
    }

    // MARK: - Through the real views

    @Test("Dragging across the column headers selects the columns it crossed")
    func dragAcrossColumnHeaders() throws {
        let grid = try Grid()
        var events: [GridEvent] = []
        grid.host.onEvent = { events.append($0) }

        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 2))
        #expect(grid.host.model.selection.ranges == [CellRange.entireColumn(2)])

        for column in 3 ... 5 {
            grid.columnHeader.mouseDragged(with: grid.event(.leftMouseDragged, atColumn: column))
        }
        // Live, before the mouse comes up — this is the thing that did nothing before.
        #expect(grid.host.model.selection.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 2 ... 5)])

        // And back past the anchor, which must reverse the band rather than leave it stuck.
        grid.columnHeader.mouseDragged(with: grid.event(.leftMouseDragged, atColumn: 0))
        #expect(grid.host.model.selection.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 0 ... 2)])

        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 0))
        guard case let .selectionChanged(final)? = events.last else {
            Issue.record("the drag never told the shell what it selected: \(events)")
            return
        }
        #expect(final.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 0 ... 2)])
        #expect(!grid.host.isAutoscrolling, "mouse-up must give the autoscroll timer back")
    }

    @Test("Dragging across the row headers selects the rows it crossed")
    func dragAcrossRowHeaders() throws {
        let grid = try Grid()
        grid.rowHeader.mouseDown(with: grid.event(.leftMouseDown, atRow: 1))
        #expect(grid.host.model.selection.ranges == [CellRange.entireRow(1)])

        for row in 2 ... 6 {
            grid.rowHeader.mouseDragged(with: grid.event(.leftMouseDragged, atRow: row))
        }
        #expect(grid.host.model.selection.ranges == [CellRange(rows: 1 ... 6, columns: 0 ... Limits.maxColumn)])

        grid.rowHeader.mouseDragged(with: grid.event(.leftMouseDragged, atRow: 0))
        #expect(grid.host.model.selection.ranges == [CellRange(rows: 0 ... 1, columns: 0 ... Limits.maxColumn)])
        grid.rowHeader.mouseUp(with: grid.event(.leftMouseUp, atRow: 0))
    }

    @Test("Shift-clicking a header extends from the anchor; ⌘-clicking adds a disjoint one")
    func modifierClicksThroughTheViews() throws {
        let grid = try Grid()
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 1))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 1))

        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 4, flags: .shift))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 4, flags: .shift))
        #expect(grid.host.model.selection.ranges == [CellRange(rows: 0 ... Limits.maxRow, columns: 1 ... 4)])

        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 6, flags: .command))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 6, flags: .command))
        #expect(grid.host.model.selection.ranges.count == 2)
        #expect(grid.host.model.selection.coversEntireColumn(6))
        #expect(grid.host.model.selection.coversEntireColumn(2), "the first band must survive the ⌘-click")
    }

    /// A drag that begins on a divider still resizes. This is the hit test the feature had to
    /// thread: a few points either side is a resize, everything else is a selection.
    @Test("A drag on the divider still resizes, and selects nothing")
    func dividerDragStillResizes() throws {
        let grid = try Grid()
        var events: [GridEvent] = []
        grid.host.onEvent = { events.append($0) }
        let before = grid.host.model.selection

        let start = grid.columnDividerPoint(2)
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, at: start))
        grid.columnHeader.mouseDragged(
            with: grid.event(.leftMouseDragged, at: CGPoint(x: start.x + 40, y: start.y))
        )
        #expect(grid.host.model.geometry.columns.size(ofIndex: 2) > grid.host.model.geometry.columns.size(ofIndex: 3))
        #expect(grid.host.model.selection == before, "a resize must not touch the selection")

        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, at: CGPoint(x: start.x + 40, y: start.y)))
        guard case .columnsResized? = events.last else {
            Issue.record("expected columnsResized, got \(events)")
            return
        }
        #expect(grid.host.model.selection == before)
    }

    @Test("Double-clicking a divider still auto-fits, and selects nothing")
    func dividerDoubleClickStillAutoFits() throws {
        let grid = try Grid()
        var events: [GridEvent] = []
        grid.host.onEvent = { events.append($0) }
        let before = grid.host.model.selection

        let point = grid.columnDividerPoint(1)
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, at: point, clickCount: 2))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, at: point, clickCount: 2))
        guard case .autoFitColumns? = events.first else {
            Issue.record("expected autoFitColumns, got \(events)")
            return
        }
        #expect(grid.host.model.selection == before)

        // The same for rows, whose divider hit test is the mirror image.
        events.removeAll()
        let rowPoint = grid.rowDividerPoint(1)
        grid.rowHeader.mouseDown(with: grid.event(.leftMouseDown, at: rowPoint, clickCount: 2))
        grid.rowHeader.mouseUp(with: grid.event(.leftMouseUp, at: rowPoint, clickCount: 2))
        guard case .autoFitRows? = events.first else {
            Issue.record("expected autoFitRows, got \(events)")
            return
        }
        #expect(grid.host.model.selection == before)
    }

    /// Holding the drag past the right edge keeps taking in columns without the pointer moving —
    /// the difference between selecting A through Z in one gesture and having to let go.
    @Test("A column drag held past the edge autoscrolls sideways, and only sideways")
    func autoscrollFollowsTheDraggedAxis() throws {
        let grid = try Grid()
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 1))

        // Past the right edge of the body, where the body drag would start scrolling too.
        let edge = grid.host.convert(CGPoint(x: grid.host.bounds.maxX - 4, y: 8), to: nil)
        grid.columnHeader.mouseDragged(with: grid.event(.leftMouseDragged, atWindowPoint: edge))
        #expect(grid.host.isAutoscrolling, "the drag reuses the body's autoscroll, it does not skip it")

        let widest = grid.host.model.selection.boundingRange.end.column
        for _ in 0 ..< 8 { grid.host.autoscrollStep() }

        #expect(grid.host.scrollOrigin.x > 0, "holding past the edge must scroll towards the columns wanted")
        #expect(
            grid.host.scrollOrigin.y == 0,
            "the pointer never left the column strip, so the sheet must not scroll vertically"
        )
        let selection = grid.host.model.selection
        #expect(selection.boundingRange.end.column > widest, "the selection has to follow the scroll")
        #expect(selection.boundingRange.start.column == 1, "and still pivot on the anchor")
        #expect(selection.coversEntireColumn(selection.boundingRange.end.column))

        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atWindowPoint: edge))
        #expect(!grid.host.isAutoscrolling)
    }

    @Test("A row drag held past the bottom autoscrolls down, and only down")
    func rowAutoscrollFollowsItsAxis() throws {
        let grid = try Grid()
        grid.rowHeader.mouseDown(with: grid.event(.leftMouseDown, atRow: 1))
        let edge = grid.host.convert(CGPoint(x: 12, y: grid.host.bounds.maxY - 4), to: nil)
        grid.rowHeader.mouseDragged(with: grid.event(.leftMouseDragged, atWindowPoint: edge))
        // Asserted before pumping: without it the step below would still scroll, because an
        // unset `lastDragWindowPoint` is the window's origin, which is past the bottom edge of a
        // flipped host. That is how this test passed against a deliberately broken `mouseDragged`.
        #expect(grid.host.isAutoscrolling, "the drag has to arm the autoscroll, not rely on stale state")

        let lowest = grid.host.model.selection.boundingRange.end.row
        for _ in 0 ..< 8 { grid.host.autoscrollStep() }

        #expect(grid.host.scrollOrigin.y > 0)
        #expect(grid.host.scrollOrigin.x == 0, "the pointer never left the row strip")
        #expect(grid.host.model.selection.boundingRange.end.row > lowest)
        #expect(grid.host.model.selection.boundingRange.start.row == 1)

        grid.rowHeader.mouseUp(with: grid.event(.leftMouseUp, atWindowPoint: edge))
        #expect(!grid.host.isAutoscrolling)
    }

    /// What the drag leaves behind has to be an ordinary range selection, because the stats pill,
    /// `⌘C` and the name box all read the selection and none of them know a header drag happened.
    @Test("What a header drag leaves behind is an ordinary range selection")
    func theResultIsARealSelection() throws {
        let grid = try Grid()
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 1))
        grid.columnHeader.mouseDragged(with: grid.event(.leftMouseDragged, atColumn: 3))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 3))

        let selection = grid.host.model.selection
        #expect(selection.boundingRange == CellRange(rows: 0 ... Limits.maxRow, columns: 1 ... 3))
        #expect(selection.boundingRange.a1String == "B1:D1048576")
        #expect(selection.cellCount == 3 * (Limits.maxRow + 1))
        #expect(!selection.isSingleCell)
        #expect(selection.contains(CellRef(row: 4, column: 2)), "a cell in the band is selected")
        #expect(!selection.contains(CellRef(row: 4, column: 0)), "and one outside it is not")
    }

    @Test("Clicking the corner selects the whole sheet")
    func cornerSelectsEverything() throws {
        let grid = try Grid()
        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 3))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 3))

        let corner = try #require(Grid.first(GridCornerView.self, in: grid.host))
        corner.mouseDown(with: grid.event(.leftMouseDown, at: CGPoint(x: 4, y: 4)))
        #expect(grid.host.model.selection.ranges == [CellRange.entireSheet])
    }

    /// A header click is a click on the grid: it takes focus, so the arrow keys that follow move
    /// the selection rather than going nowhere.
    @Test("A header click moves first responder to the grid and commits an open edit")
    func headerClickTakesFocus() throws {
        let grid = try Grid()
        var events: [GridEvent] = []
        grid.host.beginEdit(at: CellRef(row: 1, column: 1), seed: "typed")
        #expect(grid.host.editor.isEditing)
        grid.host.onEvent = { events.append($0) }

        grid.columnHeader.mouseDown(with: grid.event(.leftMouseDown, atColumn: 3))
        grid.columnHeader.mouseUp(with: grid.event(.leftMouseUp, atColumn: 3))

        #expect(!grid.host.editor.isEditing, "the edit must land somewhere, not be left in a stranded editor")
        #expect(events.contains { if case .commitEdit = $0 { true } else { false } })
        #expect(grid.host.model.selection.coversEntireColumn(3))
    }

    // MARK: - Harness

    /// A grid in a real window, with the header views and the coordinate maths to aim at them.
    ///
    /// A real `NSWindow` because `NSEvent.locationInWindow` is only meaningful in one, and because
    /// `NSView.convert(_:from: nil)` — the line every one of these handlers opens with — resolves
    /// against the view's window.
    @MainActor
    private struct Grid {
        let host: GridHostView
        let columnHeader: GridColumnHeaderView
        let rowHeader: GridRowHeaderView

        nonisolated(unsafe) static var retained: [NSWindow] = []

        init() throws {
            var store = CellStore()
            for row in 0 ..< 12 {
                for column in 0 ..< 8 {
                    try store.setCell(.number(Double(row * 8 + column)), at: CellRef(row: row, column: column))
                }
            }
            let sheet = Sheet(id: 1, name: "Report", cells: store)
            let view = GridHostView(
                model: GridRenderModel(
                    sheet: sheet, styles: StyleTable(), geometry: GridGeometry(sheet: sheet)
                )
            )
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            Self.retained.append(window)

            host = view
            columnHeader = try #require(Self.first(GridColumnHeaderView.self, in: view))
            rowHeader = try #require(Self.first(GridRowHeaderView.self, in: view))
        }

        static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews {
                if let match = first(type, in: child) { return match }
            }
            return nil
        }

        /// The middle of a column's letter — comfortably clear of both its dividers, so this
        /// aims at the header *body* and never accidentally tests the resize path.
        func columnHeaderPoint(_ column: Int) -> CGPoint {
            let columns = host.model.geometry.columns
            let centre = columns.offset(ofIndex: column) + columns.size(ofIndex: column) / 2
            return CGPoint(x: centre - host.scrollOrigin.x, y: 8)
        }

        func rowHeaderPoint(_ row: Int) -> CGPoint {
            let rows = host.model.geometry.rows
            let centre = rows.offset(ofIndex: row) + rows.size(ofIndex: row) / 2
            return CGPoint(x: 12, y: centre - host.scrollOrigin.y)
        }

        /// Exactly on a column's trailing divider — the resize target.
        func columnDividerPoint(_ column: Int) -> CGPoint {
            CGPoint(x: host.model.geometry.columns.offset(ofIndex: column + 1) - host.scrollOrigin.x, y: 8)
        }

        func rowDividerPoint(_ row: Int) -> CGPoint {
            CGPoint(x: 12, y: host.model.geometry.rows.offset(ofIndex: row + 1) - host.scrollOrigin.y)
        }

        func event(
            _ type: NSEvent.EventType,
            atColumn column: Int,
            flags: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) -> NSEvent {
            event(type, at: columnHeaderPoint(column), flags: flags, clickCount: clickCount)
        }

        func event(
            _ type: NSEvent.EventType,
            atRow row: Int,
            flags: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) -> NSEvent {
            event(type, at: rowHeaderPoint(row), in: rowHeader, flags: flags, clickCount: clickCount)
        }

        /// `point` is in `view`'s own (flipped) coordinates; the event carries it in the window's.
        func event(
            _ type: NSEvent.EventType,
            at point: CGPoint,
            in view: NSView? = nil,
            flags: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) -> NSEvent {
            event(
                type,
                atWindowPoint: (view ?? columnHeader).convert(point, to: nil),
                flags: flags,
                clickCount: clickCount
            )
        }

        func event(
            _ type: NSEvent.EventType,
            atWindowPoint point: CGPoint,
            flags: NSEvent.ModifierFlags = [],
            clickCount: Int = 1
        ) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            ) ?? NSEvent()
        }
    }
}
