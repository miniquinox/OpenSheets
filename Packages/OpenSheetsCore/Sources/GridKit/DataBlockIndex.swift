import Foundation
import SheetModel

/// Sorted lists of "which rows in this column hold data", built on demand and kept bounded.
///
/// # Why not just ask `CellStore`
///
/// ``CellStore/firstNonEmptyRow(inColumn:atOrAfter:)`` is documented as **O(populated rows)** —
/// rows live in a dictionary, so finding the next one means looking at all of them. Its own doc
/// says that is "the right trade for a keystroke and the wrong one for a frame".
///
/// A single `⌘↓` is not one call, though. Walking to the far end of a contiguous block calls it
/// once per row, which turns O(rows) into O(rows²): on a million-cell sheet that is a keystroke
/// that takes minutes. So this builds the column's row list once — a single ascending walk that
/// `CellStore` does efficiently — and every question after that is a binary search.
///
/// The cache holds a handful of axes, because a user navigates a few columns at a time and a
/// spreadsheet has 16,384 of them.
@MainActor
public final class DataBlockIndex {
    /// A cell counts as data when it holds a value or a formula. A blank-but-formatted cell does
    /// **not**: "column D is currency" must not stop a `⌘↓`, and in Excel it does not.
    public static func holdsData(_ cell: Cell) -> Bool {
        cell.value != .empty || cell.formula != nil
    }

    private var cells: CellStore
    private var columnCache: [Int: [Int]] = [:]
    private var rowCache: [Int: [Int]] = [:]
    private var columnOrder: [Int] = []
    private var rowOrder: [Int] = []
    private let capacity: Int

    public init(cells: CellStore = CellStore(), capacity: Int = 16) {
        self.cells = cells
        self.capacity = max(2, capacity)
    }

    /// Points the index at a new snapshot, dropping everything cached.
    ///
    /// Called on every model change. Rebuilding lazily is right: most edits are followed by more
    /// typing, not by a `⌘↓`.
    public func update(cells: CellStore) {
        self.cells = cells
        invalidate()
    }

    /// Drops the cached axes without changing the snapshot.
    public func invalidate() {
        columnCache.removeAll(keepingCapacity: true)
        rowCache.removeAll(keepingCapacity: true)
        columnOrder.removeAll(keepingCapacity: true)
        rowOrder.removeAll(keepingCapacity: true)
    }

    /// The rows holding data in `column`, ascending.
    public func rowsWithData(inColumn column: Int) -> [Int] {
        if let existing = columnCache[column] {
            touch(column, in: &columnOrder)
            return existing
        }
        var rows: [Int] = []
        // `forEachCell` is documented row-major and proportional to what it returns, so this is
        // one pass over the populated rows, not over 1,048,576 of them.
        cells.forEachCell(in: CellRange.entireColumn(column)) { ref, cell in
            if Self.holdsData(cell) { rows.append(ref.row) }
        }
        store(rows, forKey: column, in: &columnCache, order: &columnOrder)
        return rows
    }

    /// The columns holding data in `row`, ascending.
    public func columnsWithData(inRow row: Int) -> [Int] {
        if let existing = rowCache[row] {
            touch(row, in: &rowOrder)
            return existing
        }
        var columns: [Int] = []
        cells.forEachCell(in: CellRange.entireRow(row)) { ref, cell in
            if Self.holdsData(cell) { columns.append(ref.column) }
        }
        store(columns, forKey: row, in: &rowCache, order: &rowOrder)
        return columns
    }

    /// Whether the cell holds data. O(log n).
    public func holdsData(at ref: CellRef) -> Bool {
        cells[ref].map(Self.holdsData) ?? false
    }

    /// The snapshot's used range, or `nil` when the sheet is empty.
    public var usedRange: CellRange? { cells.usedRange }

    private func touch(_ key: Int, in order: inout [Int]) {
        if let position = order.firstIndex(of: key) {
            order.remove(at: position)
        }
        order.append(key)
    }

    private func store(_ value: [Int], forKey key: Int, in cache: inout [Int: [Int]], order: inout [Int]) {
        cache[key] = value
        touch(key, in: &order)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

// MARK: - Block edges

/// Excel's `⌘`-arrow rule, as a pure function over a sorted list of populated indices.
///
/// Isolating it from the view is what makes the thirty-plus edge cases testable: every one of
/// them is an array, a starting index, and an expected answer.
public enum DataBlockNavigator {
    /// Where `⌘`-arrow lands, moving through `populated` from `start`.
    ///
    /// The rule, exactly as Excel implements it:
    ///
    /// - **On data, next cell also data** → the far end of the contiguous block.
    /// - **On data, next cell empty** → the first cell of the next block; if there is none, the
    ///   last index on the axis. This is the case that makes `⌘↓` in a full column jump to row
    ///   1,048,576, which surprises people until they realise it is consistent.
    /// - **On empty** → the next cell holding data; if there is none, the last index.
    ///
    /// Every case collapses to a binary search plus, at most, one more.
    public static func jump(from start: Int, populated: [Int], forward: Bool, limit: Int) -> Int {
        let bound = forward ? limit - 1 : 0
        guard limit > 0 else { return 0 }
        guard start != bound else { return bound }

        let position = index(of: start, in: populated)
        let onData = position != nil

        if onData, let position {
            let neighbour = forward ? position + 1 : position - 1
            let neighbourIsAdjacent = populated.indices.contains(neighbour)
                && populated[neighbour] == start + (forward ? 1 : -1)
            if neighbourIsAdjacent {
                return blockEnd(from: position, populated: populated, forward: forward)
            }
        }

        // Either standing on the last cell of a block, or standing on a gap: both look for the
        // next populated cell beyond the current one.
        if let next = firstPopulated(beyond: start, populated: populated, forward: forward) {
            return next
        }
        return bound
    }

    /// The far end of the contiguous run containing `position`.
    ///
    /// Inside a run, `populated[j] - j` is constant, so the run's end is a binary search rather
    /// than a walk — which matters when the run is a million rows long.
    private static func blockEnd(from position: Int, populated: [Int], forward: Bool) -> Int {
        let signature = populated[position] - position
        if forward {
            var low = position
            var high = populated.count - 1
            while low < high {
                let mid = (low + high + 1) >> 1
                if populated[mid] - mid == signature { low = mid } else { high = mid - 1 }
            }
            return populated[low]
        }
        var low = 0
        var high = position
        while low < high {
            let mid = (low + high) >> 1
            if populated[mid] - mid == signature { high = mid } else { low = mid + 1 }
        }
        return populated[low]
    }

    private static func firstPopulated(beyond start: Int, populated: [Int], forward: Bool) -> Int? {
        guard !populated.isEmpty else { return nil }
        if forward {
            let position = lowerBound(populated, start + 1)
            return position < populated.count ? populated[position] : nil
        }
        let position = lowerBound(populated, start) - 1
        return position >= 0 ? populated[position] : nil
    }

    /// Position of `value` in the sorted array, or `nil`.
    static func index(of value: Int, in populated: [Int]) -> Int? {
        let position = lowerBound(populated, value)
        return position < populated.count && populated[position] == value ? position : nil
    }

    /// First position whose value is `>= value`.
    static func lowerBound(_ populated: [Int], _ value: Int) -> Int {
        var low = 0
        var high = populated.count
        while low < high {
            let mid = (low + high) >> 1
            if populated[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
