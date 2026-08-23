import Foundation
import SheetModel

/// Merged regions, arranged so the renderer can ask about a cell without scanning the list.
///
/// ``Sheet/merge(containing:)`` is linear and says so — "build an index if you need this per
/// cell per frame". This is that index. A dashboard sheet with a few thousand merges would
/// otherwise cost thousands of comparisons per cell per frame, which is the sort of thing that
/// only shows up on someone else's file.
///
/// The structure is an interval list: merges sorted by start row, with a running maximum of end
/// rows so a query can stop walking backwards as soon as no earlier merge can still reach the
/// row being asked about.
public struct MergeIndex: Sendable {
    private let sorted: [CellRange]
    /// `reach[i]` is the largest `end.row` among `sorted[0 ... i]`.
    private let reach: [Int]

    /// An empty index. Free, and the common case.
    public static let empty = MergeIndex([])

    public init(_ merges: [CellRange]) {
        let ordered = merges.sorted {
            $0.start.row == $1.start.row ? $0.start.column < $1.start.column : $0.start.row < $1.start.row
        }
        var running: [Int] = []
        running.reserveCapacity(ordered.count)
        var highest = Int.min
        for merge in ordered {
            highest = max(highest, merge.end.row)
            running.append(highest)
        }
        sorted = ordered
        reach = running
    }

    /// Whether the sheet has any merges at all.
    public var isEmpty: Bool { sorted.isEmpty }

    /// How many merges the sheet has.
    public var count: Int { sorted.count }

    /// Every merge, ordered by start row then start column.
    public var all: [CellRange] { sorted }

    /// The merge covering `ref`, or `nil`.
    public func merge(containing ref: CellRef) -> CellRange? {
        guard !sorted.isEmpty else { return nil }
        var index = lastIndex(startingAtOrBefore: ref.row)
        while index >= 0 {
            // No merge at or before here reaches this row, so nothing further back can either.
            guard reach[index] >= ref.row else { return nil }
            let candidate = sorted[index]
            if candidate.contains(ref) { return candidate }
            index -= 1
        }
        return nil
    }

    /// Whether `ref` is covered by a merge but is not its anchor — the cells whose content Excel
    /// hides and whose clicks land on the anchor instead.
    public func isCovered(_ ref: CellRef) -> Bool {
        guard let merge = merge(containing: ref) else { return false }
        return merge.start != ref
    }

    /// The anchor cell for `ref`: the merge's top-left, or `ref` itself.
    public func anchor(of ref: CellRef) -> CellRef {
        merge(containing: ref)?.start ?? ref
    }

    /// The range `ref` really occupies — its merge, or a one-cell range.
    public func span(of ref: CellRef) -> CellRange {
        merge(containing: ref) ?? CellRange(ref)
    }

    /// Every merge overlapping `range`, ordered.
    ///
    /// Used once per frame to widen the drawn rectangle: a merge that starts above the visible
    /// rect still paints into it, and a renderer that only looks at visible rows loses the top
    /// half of every merged title.
    public func merges(intersecting range: CellRange) -> [CellRange] {
        guard !sorted.isEmpty else { return [] }
        var result: [CellRange] = []
        var index = lastIndex(startingAtOrBefore: range.end.row)
        while index >= 0 {
            guard reach[index] >= range.start.row else { break }
            let candidate = sorted[index]
            if candidate.intersects(range) { result.append(candidate) }
            index -= 1
        }
        return result.reversed()
    }

    /// The smallest range that covers `range` plus every merge it touches.
    ///
    /// One call turns "the visible cells" into "the cells that paint into the visible rect".
    public func expanded(_ range: CellRange) -> CellRange {
        var result = range
        for merge in merges(intersecting: range) {
            result = result.union(merge)
        }
        return result
    }

    /// Index of the last merge whose start row is `<= row`, or `-1`.
    private func lastIndex(startingAtOrBefore row: Int) -> Int {
        var low = 0
        var high = sorted.count - 1
        var best = -1
        while low <= high {
            let mid = (low + high) >> 1
            if sorted[mid].start.row <= row {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }
}
