import CoreGraphics
import Foundation
import SheetModel

/// Every keyboard movement the grid supports, named after what it means rather than what key
/// produces it — the same motion arrives from an arrow key, a `⌘`-arrow, and a menu item.
public enum GridMotion: Sendable, Hashable {
    case up, down, left, right
    /// `⌘↑` and friends: to the edge of the data block.
    case blockUp, blockDown, blockLeft, blockRight
    /// `Home` — the first column of the current row.
    case rowStart
    /// `End`, then an arrow, is Excel's other block motion; plain `End` alone moves to the last
    /// populated column of the row, which is what this is.
    case rowEnd
    /// `⌘Home` — `A1`, always, whatever is frozen.
    case sheetStart
    /// `⌘End` — the bottom-right of the used range.
    case sheetEnd
    case pageUp, pageDown
    /// `⌥PageUp` / `⌥PageDown` — a screenful sideways.
    case pageLeft, pageRight
}

/// Resolves a movement into a destination cell, and a keystroke into a new selection.
///
/// Pure with respect to the view: it takes a geometry, a merge index and a data index, and
/// returns a ``GridSelection``. That is what lets the thirty-plus `⌘`-arrow cases be tests
/// rather than a manual pass through the app.
@MainActor
public struct GridNavigator {
    public var geometry: GridGeometry
    public var merges: MergeIndex
    public var blocks: DataBlockIndex
    /// The bottom-right of `⌘End`. `nil` on an empty sheet, where `⌘End` goes to `A1`.
    public var usedRange: CellRange?

    public init(
        geometry: GridGeometry,
        merges: MergeIndex = .empty,
        blocks: DataBlockIndex,
        usedRange: CellRange? = nil
    ) {
        self.geometry = geometry
        self.merges = merges
        self.blocks = blocks
        self.usedRange = usedRange
    }

    // MARK: - Destination

    /// Where a motion lands, starting from `ref`.
    ///
    /// `viewport` sizes a page for Page Up/Down. Pass the body pane's size, not the window's:
    /// a frozen header does not scroll, so it is not part of a page.
    public func destination(from ref: CellRef, motion: GridMotion, viewport: CGSize = .zero) -> CellRef {
        let span = merges.span(of: ref)
        switch motion {
        case .up:
            return step(row: span.start.row - 1, column: ref.column, movingDown: false)
        case .down:
            return step(row: span.end.row + 1, column: ref.column, movingDown: true)
        case .left:
            return step(row: ref.row, column: span.start.column - 1, movingRight: false)
        case .right:
            return step(row: ref.row, column: span.end.column + 1, movingRight: true)

        case .blockUp, .blockDown:
            let forward = motion == .blockDown
            let populated = blocks.rowsWithData(inColumn: ref.column)
            let row = DataBlockNavigator.jump(
                from: ref.row, populated: populated, forward: forward, limit: geometry.rows.count
            )
            return snap(CellRef(row: row, column: ref.column))

        case .blockLeft, .blockRight:
            let forward = motion == .blockRight
            let populated = blocks.columnsWithData(inRow: ref.row)
            let column = DataBlockNavigator.jump(
                from: ref.column, populated: populated, forward: forward, limit: geometry.columns.count
            )
            return snap(CellRef(row: ref.row, column: column))

        case .rowStart:
            return snap(CellRef(row: ref.row, column: geometry.columns.firstVisibleIndex(atOrAfter: 0) ?? 0))

        case .rowEnd:
            let populated = blocks.columnsWithData(inRow: ref.row)
            return snap(CellRef(row: ref.row, column: populated.last ?? ref.column))

        case .sheetStart:
            return snap(.origin)

        case .sheetEnd:
            return snap(usedRange?.end ?? .origin)

        case .pageUp, .pageDown:
            let step = geometry.rowsPerPage(bodyHeight: viewport.height, from: ref.row)
            let row = motion == .pageDown ? ref.row + step : ref.row - step
            return snap(CellRef(row: clamp(row, limit: geometry.rows.count), column: ref.column))

        case .pageLeft, .pageRight:
            let step = geometry.columnsPerPage(bodyWidth: viewport.width, from: ref.column)
            let column = motion == .pageRight ? ref.column + step : ref.column - step
            return snap(CellRef(row: ref.row, column: clamp(column, limit: geometry.columns.count)))
        }
    }

    /// Applies a motion to a selection.
    ///
    /// Extending keeps ``GridSelection/anchor`` and moves the active cell, which is what makes
    /// repeated `⇧↓` grow from where the user started rather than creep.
    public func apply(
        _ motion: GridMotion,
        extending: Bool,
        to selection: GridSelection,
        viewport: CGSize = .zero
    ) -> GridSelection {
        var result = selection
        let target = destination(from: selection.active, motion: motion, viewport: viewport)
        if extending {
            result.extend(to: target, span: merges.merge(containing: target))
        } else {
            result.select(target, span: merges.merge(containing: target))
        }
        return result
    }

    /// Tab and Enter: move inside a multi-cell selection, or move the selection itself.
    public func advance(
        _ direction: AdvanceDirection,
        in selection: GridSelection
    ) -> GridSelection {
        if let inside = selection.advancingActive(direction) {
            return inside
        }
        let motion: GridMotion = switch direction {
        case .forward: .right
        case .backward: .left
        case .down: .down
        case .up: .up
        }
        return apply(motion, extending: false, to: selection)
    }

    // MARK: - Helpers

    /// One step along the row axis, skipping hidden rows and clamping at the ends.
    private func step(row: Int, column: Int, movingDown: Bool) -> CellRef {
        guard row >= 0, row < geometry.rows.count else {
            return snap(CellRef(row: clamp(row, limit: geometry.rows.count), column: column))
        }
        let visible = movingDown
            ? geometry.rows.firstVisibleIndex(atOrAfter: row)
            : geometry.rows.lastVisibleIndex(atOrBefore: row)
        return snap(CellRef(row: visible ?? clamp(row, limit: geometry.rows.count), column: column))
    }

    private func step(row: Int, column: Int, movingRight: Bool) -> CellRef {
        guard column >= 0, column < geometry.columns.count else {
            return snap(CellRef(row: row, column: clamp(column, limit: geometry.columns.count)))
        }
        let visible = movingRight
            ? geometry.columns.firstVisibleIndex(atOrAfter: column)
            : geometry.columns.lastVisibleIndex(atOrBefore: column)
        return snap(CellRef(row: row, column: visible ?? clamp(column, limit: geometry.columns.count)))
    }

    /// Landing inside a merge means landing on its anchor — the only cell of a merge that has
    /// content, and the only one Excel will let you edit.
    private func snap(_ ref: CellRef) -> CellRef {
        merges.anchor(of: ref.clamped)
    }

    private func clamp(_ value: Int, limit: Int) -> Int {
        max(0, min(value, limit - 1))
    }
}
