import CoreGraphics
import Foundation
import SheetModel

/// One of the up to four independently-clipped regions a frozen sheet is drawn in.
///
/// Freezing two rows and one column gives all four: the corner never moves, the top band
/// scrolls horizontally only, the left band vertically only, and the body scrolls both ways.
/// Each is clipped to its own rectangle, which is what stops a wide cell in the frozen band
/// from bleeding across the divider.
public enum GridPane: String, Sendable, Hashable, CaseIterable {
    /// Frozen rows × frozen columns. Fixed on both axes.
    case corner
    /// Frozen rows × scrolling columns.
    case top
    /// Scrolling rows × frozen columns.
    case left
    /// The scrolling quadrant. Always present, even with nothing frozen.
    case body

    /// Whether this pane moves when the user scrolls horizontally.
    public var scrollsHorizontally: Bool { self == .top || self == .body }
    /// Whether this pane moves when the user scrolls vertically.
    public var scrollsVertically: Bool { self == .left || self == .body }
}

/// Where every row and column lives, in points.
///
/// Sheet space has its origin at the top-left of cell `A1` and grows down and right — the grid's
/// document view is flipped so that this is also its own coordinate space, minus the frozen
/// bands. Everything here is derived from two ``AxisMetrics``, so every question is a binary
/// search and none of it depends on how far down the sheet you are.
public struct GridGeometry: Sendable, Equatable {
    /// Row heights, already scaled by ``zoom``.
    public let rows: AxisMetrics
    /// Column widths, already scaled by ``zoom``.
    public let columns: AxisMetrics
    /// Rows locked at the top. Clamped to something that leaves the body pane usable.
    public let frozenRows: Int
    /// Columns locked at the left.
    public let frozenColumns: Int
    /// 1.0 at 100%. Already folded into ``rows`` and ``columns``; kept for hit-test maths and
    /// for scaling stroke widths that should *not* grow with zoom.
    public let zoom: Double

    public init(rows: AxisMetrics, columns: AxisMetrics, frozenRows: Int, frozenColumns: Int, zoom: Double) {
        self.rows = rows
        self.columns = columns
        self.frozenRows = max(0, min(frozenRows, max(0, rows.count - 1)))
        self.frozenColumns = max(0, min(frozenColumns, max(0, columns.count - 1)))
        self.zoom = zoom
    }

    /// Builds the geometry for a sheet at a zoom level.
    ///
    /// A split (as opposed to frozen) sheet is drawn unsplit: both halves of a split scroll, so
    /// it is a view-state feature rather than a layout one, and pretending otherwise would put a
    /// divider where the user cannot move it. ``FrozenPanes/isSplit`` still round-trips.
    public init(sheet: Sheet, zoom: Double = 1) {
        self.init(
            rows: AxisMetrics(
                sizes: sheet.rowHeights,
                hidden: sheet.hiddenRows,
                count: Limits.rowCount,
                scale: zoom
            ),
            columns: AxisMetrics(
                sizes: sheet.columnWidths,
                hidden: sheet.hiddenColumns,
                count: Limits.columnCount,
                scale: zoom
            ),
            frozenRows: sheet.frozen.frozenRows,
            frozenColumns: sheet.frozen.frozenColumns,
            zoom: zoom
        )
    }

    // MARK: - Frozen bands

    /// Height of the frozen row band, in points.
    public var frozenHeight: Double {
        frozenRows > 0 ? rows.offset(ofIndex: frozenRows) : 0
    }

    /// Width of the frozen column band, in points.
    public var frozenWidth: Double {
        frozenColumns > 0 ? columns.offset(ofIndex: frozenColumns) : 0
    }

    /// The size of the scrollable document — the whole sheet minus the frozen bands, which do
    /// not scroll and therefore must not contribute to the scroll range.
    public var scrollableSize: CGSize {
        CGSize(
            width: max(0, columns.totalExtent - frozenWidth),
            height: max(0, rows.totalExtent - frozenHeight)
        )
    }

    /// Whether anything is frozen.
    public var hasFrozenPanes: Bool { frozenRows > 0 || frozenColumns > 0 }

    /// The panes this sheet actually needs drawing, outermost first.
    public var activePanes: [GridPane] {
        switch (frozenRows > 0, frozenColumns > 0) {
        case (false, false): [.body]
        case (true, false): [.top, .body]
        case (false, true): [.left, .body]
        case (true, true): [.corner, .top, .left, .body]
        }
    }

    /// The index ranges a pane is responsible for, or `nil` when the sheet has no such pane.
    ///
    /// The scrolling ends are open — clipped later against the visible rect — so this returns
    /// the pane's *fixed* end only.
    public func fixedRange(of pane: GridPane) -> (rows: ClosedRange<Int>?, columns: ClosedRange<Int>?) {
        switch pane {
        case .corner:
            (frozenRows > 0 ? 0 ... (frozenRows - 1) : nil, frozenColumns > 0 ? 0 ... (frozenColumns - 1) : nil)
        case .top:
            (frozenRows > 0 ? 0 ... (frozenRows - 1) : nil, nil)
        case .left:
            (nil, frozenColumns > 0 ? 0 ... (frozenColumns - 1) : nil)
        case .body:
            (nil, nil)
        }
    }

    // MARK: - Sheet space

    /// The rectangle a cell occupies in sheet space.
    public func sheetRect(row: Int, column: Int) -> CGRect {
        GridInstrumentation.count(GridInstrumentation.cellLookups)
        let x = columns.offset(ofIndex: column)
        let y = rows.offset(ofIndex: row)
        return CGRect(x: x, y: y, width: columns.size(ofIndex: column), height: rows.size(ofIndex: row))
    }

    /// The rectangle a cell occupies in sheet space.
    public func sheetRect(of ref: CellRef) -> CGRect {
        sheetRect(row: ref.row, column: ref.column)
    }

    /// The rectangle a range occupies in sheet space — the union of its corners.
    public func sheetRect(of range: CellRange) -> CGRect {
        let x = columns.offset(ofIndex: range.start.column)
        let y = rows.offset(ofIndex: range.start.row)
        return CGRect(
            x: x,
            y: y,
            width: columns.offset(ofIndex: range.end.column + 1) - x,
            height: rows.offset(ofIndex: range.end.row + 1) - y
        )
    }

    /// The cell under a point in sheet space, clamped to the sheet.
    public func cellRef(atSheetPoint point: CGPoint) -> CellRef {
        CellRef(row: rows.index(atOffset: point.y), column: columns.index(atOffset: point.x))
    }

    /// Every cell touching a rectangle of sheet space. Two axis lookups per axis, no scans.
    public func cellRange(inSheetRect rect: CGRect) -> CellRange {
        let rowRange = rows.indices(fromOffset: rect.minY, toOffset: rect.maxY)
        let columnRange = columns.indices(fromOffset: rect.minX, toOffset: rect.maxX)
        return CellRange(rows: rowRange, columns: columnRange)
    }

    // MARK: - Document space

    /// Sheet-space offset that maps to the document view's origin.
    ///
    /// The document view holds only the scrolling quadrant, so its `(0, 0)` is the first
    /// unfrozen cell — otherwise the frozen band would be scrollable, which is the one thing it
    /// must not be.
    public var documentOrigin: CGPoint {
        CGPoint(x: frozenWidth, y: frozenHeight)
    }

    /// Converts a point in the document view to sheet space.
    public func sheetPoint(fromDocument point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + frozenWidth, y: point.y + frozenHeight)
    }

    /// Converts a rectangle in the document view to sheet space.
    public func sheetRect(fromDocument rect: CGRect) -> CGRect {
        rect.offsetBy(dx: frozenWidth, dy: frozenHeight)
    }

    /// Converts a rectangle in sheet space to the document view's space.
    public func documentRect(fromSheet rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frozenWidth, dy: -frozenHeight)
    }

    /// The first row of the scrolling body — the row just past the frozen band.
    public var firstScrollingRow: Int { frozenRows }
    /// The first column of the scrolling body.
    public var firstScrollingColumn: Int { frozenColumns }

    // MARK: - Scrolling to a cell

    /// The document-space origin that brings `ref` fully into a viewport of `size`.
    ///
    /// Returns `nil` when the cell is already visible, so a caller can avoid a pointless scroll —
    /// which matters because a scroll during a keyboard repeat is what makes arrow-key navigation
    /// feel jumpy.
    public func scrollOrigin(
        toReveal ref: CellRef,
        currentOrigin: CGPoint,
        viewportSize: CGSize,
        padding: Double = 0
    ) -> CGPoint? {
        let cell = documentRect(fromSheet: sheetRect(of: ref))
        // A cell inside a frozen band is always on screen; scrolling to it means scrolling nowhere.
        guard ref.row >= frozenRows || ref.column >= frozenColumns else { return nil }

        var origin = currentOrigin
        var moved = false

        if ref.column >= frozenColumns {
            if cell.minX < origin.x + padding {
                origin.x = max(0, cell.minX - padding)
                moved = true
            } else if cell.maxX > origin.x + viewportSize.width - padding {
                origin.x = max(0, cell.maxX - viewportSize.width + padding)
                moved = true
            }
        }
        if ref.row >= frozenRows {
            if cell.minY < origin.y + padding {
                origin.y = max(0, cell.minY - padding)
                moved = true
            } else if cell.maxY > origin.y + viewportSize.height - padding {
                origin.y = max(0, cell.maxY - viewportSize.height + padding)
                moved = true
            }
        }
        return moved ? origin : nil
    }

    /// How many rows a Page Down should move, given the height available for the body pane.
    ///
    /// Excel moves by a screenful minus nothing — the row at the bottom becomes the row at the
    /// top only in some versions — so this returns a whole screenful, never fewer than one row.
    public func rowsPerPage(bodyHeight: Double, from row: Int) -> Int {
        guard bodyHeight > 0 else { return 1 }
        let top = rows.offset(ofIndex: row)
        let target = rows.index(atOffset: top + bodyHeight)
        return max(1, target - row)
    }

    /// How many columns fit across the body pane, for `⌥`-Page navigation.
    public func columnsPerPage(bodyWidth: Double, from column: Int) -> Int {
        guard bodyWidth > 0 else { return 1 }
        let left = columns.offset(ofIndex: column)
        let target = columns.index(atOffset: left + bodyWidth)
        return max(1, target - column)
    }
}
