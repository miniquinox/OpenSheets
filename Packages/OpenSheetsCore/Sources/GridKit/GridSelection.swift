import Foundation
import SheetModel

/// Which way Tab and Enter move.
public enum AdvanceDirection: Sendable, Hashable, CaseIterable {
    /// Tab.
    case forward
    /// Shift-Tab.
    case backward
    /// Enter.
    case down
    /// Shift-Enter.
    case up
}

/// What is selected, and where the caret is inside it.
///
/// A spreadsheet selection is not one rectangle. `⌘`-clicking adds a second, and formulas,
/// formatting, and delete all operate on the union — so the model is a list of ranges plus an
/// **active cell**, which is the one the formula bar edits and the one arrow keys move.
///
/// The active cell always lies inside ``activeRange``, and ``anchor`` is the corner a
/// shift-extend pivots around. Keeping the anchor explicit is what makes shift-click behave:
/// extending twice from the same origin must not creep.
public struct GridSelection: Sendable, Hashable {
    /// At least one range, in the order the user made them. Never empty.
    public private(set) var ranges: [CellRange]

    /// Which of ``ranges`` holds ``active``.
    public private(set) var activeRangeIndex: Int

    /// The cell the formula bar shows and the arrows move.
    public private(set) var active: CellRef

    /// The fixed corner a shift-extend pivots around.
    public private(set) var anchor: CellRef

    /// A single-cell selection.
    public init(active: CellRef = .origin) {
        ranges = [CellRange(active)]
        activeRangeIndex = 0
        self.active = active
        anchor = active
    }

    /// A selection built from parts. Invalid input is repaired rather than trapped — a bad
    /// selection is a UI bug, and crashing the window over one helps nobody.
    public init(ranges: [CellRange], active: CellRef, anchor: CellRef, activeRangeIndex: Int = 0) {
        let cleaned = ranges.isEmpty ? [CellRange(active)] : ranges.map(\.clampedToSheet)
        self.ranges = cleaned
        self.activeRangeIndex = min(max(0, activeRangeIndex), cleaned.count - 1)
        self.active = active.clamped
        self.anchor = anchor.clamped
    }

    // MARK: - Reading

    /// The range holding the active cell.
    public var activeRange: CellRange { ranges[activeRangeIndex] }

    /// The smallest rectangle covering every range. What ⌘C copies.
    public var boundingRange: CellRange {
        ranges.dropFirst().reduce(ranges[0]) { $0.union($1) }
    }

    /// Whether exactly one cell is selected.
    public var isSingleCell: Bool { ranges.count == 1 && ranges[0].isSingleCell }

    /// Cells covered, counting overlaps once per range rather than deduplicating — the number
    /// the status bar shows, and the number Excel shows.
    public var cellCount: Int { ranges.reduce(0) { $0 + $1.cellCount } }

    /// Whether any range covers `ref`.
    public func contains(_ ref: CellRef) -> Bool {
        ranges.contains { $0.contains(ref) }
    }

    /// Whether any range overlaps `range`.
    public func intersects(_ range: CellRange) -> Bool {
        ranges.contains { $0.intersects(range) }
    }

    /// Whether any range touches this row — the test for tinting a row header.
    public func intersectsRow(_ row: Int) -> Bool {
        ranges.contains { $0.start.row <= row && row <= $0.end.row }
    }

    /// Whether any range touches this column.
    public func intersectsColumn(_ column: Int) -> Bool {
        ranges.contains { $0.start.column <= column && column <= $0.end.column }
    }

    /// Whether a range selects the whole of this row — a row-header click.
    public func coversEntireRow(_ row: Int) -> Bool {
        ranges.contains {
            $0.start.row <= row && row <= $0.end.row
                && $0.start.column == 0 && $0.end.column >= Limits.maxColumn
        }
    }

    /// Whether a range selects the whole of this column.
    public func coversEntireColumn(_ column: Int) -> Bool {
        ranges.contains {
            $0.start.column <= column && column <= $0.end.column
                && $0.start.row == 0 && $0.end.row >= Limits.maxRow
        }
    }

    // MARK: - Mutating

    /// Replaces everything with one range, putting the caret at `active`.
    public mutating func select(_ range: CellRange, active newActive: CellRef? = nil) {
        let target = range.clampedToSheet
        ranges = [target]
        activeRangeIndex = 0
        active = (newActive.map { target.contains($0) ? $0 : target.start } ?? target.start).clamped
        anchor = target.start
    }

    /// Replaces everything with one cell — or with the merge that cell belongs to.
    public mutating func select(_ ref: CellRef, span: CellRange? = nil) {
        let target = span ?? CellRange(ref)
        ranges = [target.clampedToSheet]
        activeRangeIndex = 0
        active = ref.clamped
        anchor = ref.clamped
    }

    /// Grows the active range from ``anchor`` to `ref` — shift-click and shift-arrow.
    ///
    /// `span` lets a merged cell extend to its whole region: shift-clicking the middle of a
    /// merge has to take the merge, or the selection rectangle cuts through a drawn cell.
    public mutating func extend(to ref: CellRef, span: CellRange? = nil) {
        let target = ref.clamped
        var range = CellRange(
            start: CellRef(row: min(anchor.row, target.row), column: min(anchor.column, target.column)),
            end: CellRef(row: max(anchor.row, target.row), column: max(anchor.column, target.column))
        )
        if let span { range = range.union(span) }
        ranges[activeRangeIndex] = range.clampedToSheet
        active = target
    }

    /// Adds a disjoint range and moves the caret into it — `⌘`-click.
    public mutating func addRange(_ range: CellRange, active newActive: CellRef? = nil) {
        let target = range.clampedToSheet
        ranges.append(target)
        activeRangeIndex = ranges.count - 1
        active = (newActive.map { target.contains($0) ? $0 : target.start } ?? target.start).clamped
        anchor = target.start
    }

    /// Moves the caret without changing what is selected. Used by ⌘-clicking a cell that is
    /// already selected, and by Tab.
    public mutating func setActive(_ ref: CellRef) {
        let target = ref.clamped
        active = target
        anchor = target
        if let index = ranges.firstIndex(where: { $0.contains(target) }) {
            activeRangeIndex = index
        } else {
            ranges = [CellRange(target)]
            activeRangeIndex = 0
        }
    }

    /// Drops every range but the active one.
    public mutating func collapseToActiveRange() {
        let keep = activeRange
        ranges = [keep]
        activeRangeIndex = 0
    }

    // MARK: - Tab and Enter

    /// Moves the caret one step inside the selection, wrapping at the edges — Excel's rule.
    ///
    /// Tab runs left-to-right and wraps to the next row; Enter runs top-to-bottom and wraps to
    /// the next column. Falling off the last cell of a range moves into the next range, and off
    /// the last range wraps back to the first. This is why people select a block before typing:
    /// the caret stays inside it no matter how many times they press Tab.
    ///
    /// Returns `nil` when the selection is a single cell, because then Tab and Enter move the
    /// *selection* across the sheet instead — a different operation, and the navigator's job.
    public func advancingActive(_ direction: AdvanceDirection) -> GridSelection? {
        guard !isSingleCell else { return nil }
        var result = self
        let range = activeRange

        switch direction {
        case .forward:
            if active.column < range.end.column {
                result.active = CellRef(row: active.row, column: active.column + 1)
            } else if active.row < range.end.row {
                result.active = CellRef(row: active.row + 1, column: range.start.column)
            } else {
                result.moveToRange(offset: 1, corner: .topLeft)
            }
        case .backward:
            if active.column > range.start.column {
                result.active = CellRef(row: active.row, column: active.column - 1)
            } else if active.row > range.start.row {
                result.active = CellRef(row: active.row - 1, column: range.end.column)
            } else {
                result.moveToRange(offset: -1, corner: .bottomRight)
            }
        case .down:
            if active.row < range.end.row {
                result.active = CellRef(row: active.row + 1, column: active.column)
            } else if active.column < range.end.column {
                result.active = CellRef(row: range.start.row, column: active.column + 1)
            } else {
                result.moveToRange(offset: 1, corner: .topLeft)
            }
        case .up:
            if active.row > range.start.row {
                result.active = CellRef(row: active.row - 1, column: active.column)
            } else if active.column > range.start.column {
                result.active = CellRef(row: range.end.row, column: active.column - 1)
            } else {
                result.moveToRange(offset: -1, corner: .bottomRight)
            }
        }
        result.anchor = result.active
        return result
    }

    private enum Corner { case topLeft, bottomRight }

    private mutating func moveToRange(offset: Int, corner: Corner) {
        let count = ranges.count
        activeRangeIndex = ((activeRangeIndex + offset) % count + count) % count
        active = corner == .topLeft ? activeRange.start : activeRange.end
    }
}

extension GridSelection: CustomStringConvertible {
    public var description: String {
        "GridSelection(\(ranges.map(\.a1String).joined(separator: ",")) active: \(active.a1String))"
    }
}
