import Foundation
import SheetModel

/// One axis of the grid — rows or columns — flattened into bands you can binary-search.
///
/// # Why this exists
///
/// A sheet has 1,048,576 rows. Answering "which row is at y = 4,193,280?" by adding up row
/// heights is a linear scan, and a linear scan inside `draw(_:)` is the difference between a
/// grid that flings and a grid that stutters at the bottom of a large sheet.
///
/// ``RunLengthArray`` already answers both questions in O(runCount) — see its `offset(ofIndex:)`
/// and `index(atOffset:)`. That is fine for a sheet with three customised bands and wrong for
/// one with three thousand: a spreadsheet where every row has been auto-fitted has a run per
/// row, and O(runCount) is O(rows) again.
///
/// So this type snapshots the run-length array **once per layout** into bands carrying
/// **cumulative offsets**, which turns both questions into a binary search: O(log bands),
/// independent of how far down the sheet you are. Scrolling to row 1,048,576 costs exactly what
/// scrolling to row 3 costs, which is the property ``GridInstrumentation/axisLookups`` asserts.
///
/// # Hidden rows and columns
///
/// A hidden index is a band of size zero, not a missing band. That keeps indices contiguous —
/// row 5 is still row 5 with rows 2–4 hidden — while ``index(atOffset:)`` never lands on one,
/// because a zero-width band cannot contain a point.
public struct AxisMetrics: Sendable, Equatable {
    /// A contiguous run of indices that all have the same size.
    public struct Band: Sendable, Equatable {
        /// First index in the band.
        public let start: Int
        /// How many indices the band covers. Always ≥ 1.
        public let length: Int
        /// Points per index. Zero for a hidden band.
        public let size: Double
        /// Distance from the axis origin to ``start``'s leading edge.
        public let offset: Double

        /// One past the last index.
        public var end: Int { start + length }
        /// Distance from the axis origin to the band's trailing edge.
        public var endOffset: Double { offset + Double(length) * size }
    }

    /// Ascending, contiguous, gapless, and covering `0 ..< count`.
    public let bands: [Band]

    /// How many indices the axis has — 1,048,576 rows or 16,384 columns.
    public let count: Int

    /// Total length of the axis in points.
    public let totalExtent: Double

    /// What an index with no run of its own measures, already scaled.
    public let defaultSize: Double

    // MARK: - Building

    /// Flattens sizes and hidden flags into bands.
    ///
    /// `scale` is the zoom factor; applying it here rather than through a `CGContext` transform
    /// keeps hit-testing and drawing in the same coordinate space, so a click at 200% lands on
    /// the cell the user sees.
    ///
    /// Sizes below `minimumSize` are clamped up — a file can legally say a column is 0.3pt wide,
    /// and a grid that honours that is a grid you cannot click on. A *hidden* index is still
    /// zero, because that is a different thing and the UI has to offer "unhide" for it.
    public init(
        sizes: RunLengthArray<Double>,
        hidden: RunLengthArray<Bool>,
        count: Int,
        scale: Double = 1,
        minimumSize: Double = 1
    ) {
        let limit = max(0, count)
        self.count = limit
        defaultSize = Self.resolve(sizes.defaultValue, scale: scale, minimum: minimumSize)

        guard limit > 0 else {
            bands = []
            totalExtent = 0
            return
        }

        // Band boundaries are exactly where either array changes value. Collecting them from
        // the runs is what keeps this O(runs) rather than O(count).
        var boundaries: Set<Int> = [0]
        for run in sizes.runs {
            boundaries.insert(run.range.lowerBound)
            boundaries.insert(run.range.upperBound + 1)
        }
        for run in hidden.runs {
            boundaries.insert(run.range.lowerBound)
            boundaries.insert(run.range.upperBound + 1)
        }
        let cuts = boundaries.filter { $0 >= 0 && $0 < limit }.sorted()

        var built: [Band] = []
        built.reserveCapacity(cuts.count)
        var offset = 0.0

        for (position, start) in cuts.enumerated() {
            let end = position + 1 < cuts.count ? cuts[position + 1] : limit
            guard end > start else { continue }
            let size = hidden[start] ? 0 : Self.resolve(sizes[start], scale: scale, minimum: minimumSize)

            // Merging equal neighbours keeps `bands` proportional to distinct *sizes*, not to
            // how many times the file wrote to the two arrays.
            if let last = built.last, last.size == size {
                built[built.count - 1] = Band(
                    start: last.start,
                    length: end - last.start,
                    size: size,
                    offset: last.offset
                )
            } else {
                built.append(Band(start: start, length: end - start, size: size, offset: offset))
            }
            offset += Double(end - start) * size
        }

        bands = built
        totalExtent = offset
    }

    /// A uniform axis — every index the same size. The common case, and one band.
    public init(uniformSize: Double, count: Int) {
        self.init(
            sizes: RunLengthArray(defaultValue: uniformSize),
            hidden: RunLengthArray(defaultValue: false),
            count: count
        )
    }

    private static func resolve(_ raw: Double, scale: Double, minimum: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 0 }
        return max(minimum, raw * scale)
    }

    // MARK: - Lookups

    /// Index of the band containing `index`, or `nil` when the index is off the axis.
    ///
    /// O(log bands).
    @inline(__always)
    private func bandIndex(containing index: Int) -> Int? {
        guard index >= 0, index < count, !bands.isEmpty else { return nil }
        var low = 0
        var high = bands.count - 1
        while low < high {
            let mid = (low + high + 1) >> 1
            if bands[mid].start <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The leading edge of `index` — a row's top, a column's left.
    ///
    /// Clamps: a negative index is at 0, an index past the end is at ``totalExtent``. O(log bands).
    public func offset(ofIndex index: Int) -> Double {
        GridInstrumentation.count(GridInstrumentation.axisLookups)
        guard index > 0 else { return 0 }
        guard index < count else { return totalExtent }
        guard let position = bandIndex(containing: index) else { return totalExtent }
        let band = bands[position]
        return band.offset + Double(index - band.start) * band.size
    }

    /// The size of one index, in points. Zero when it is hidden.
    public func size(ofIndex index: Int) -> Double {
        guard let position = bandIndex(containing: index) else { return 0 }
        return bands[position].size
    }

    /// Whether `index` is hidden — which here means "occupies no space".
    public func isHidden(_ index: Int) -> Bool {
        size(ofIndex: index) == 0
    }

    /// Total extent of an inclusive index range.
    public func extent(of range: ClosedRange<Int>) -> Double {
        offset(ofIndex: range.upperBound + 1) - offset(ofIndex: range.lowerBound)
    }

    /// The index whose band contains `point`, clamped to the axis.
    ///
    /// Never returns a hidden index: a zero-width band contains no point, so the search steps
    /// past it to the next one that does. O(log bands).
    public func index(atOffset point: Double) -> Int {
        GridInstrumentation.count(GridInstrumentation.axisLookups)
        guard count > 0 else { return 0 }
        guard point > 0 else { return 0 }
        guard point < totalExtent, !bands.isEmpty else { return count - 1 }

        // First band whose trailing edge is strictly past `point`. Zero-width bands have
        // `endOffset == offset`, so they can never satisfy this and are skipped for free.
        var low = 0
        var high = bands.count - 1
        while low < high {
            let mid = (low + high) >> 1
            if bands[mid].endOffset > point { high = mid } else { low = mid + 1 }
        }
        let band = bands[low]
        guard band.size > 0 else { return min(band.start, count - 1) }
        let within = Int((point - band.offset) / band.size)
        return min(band.start + max(0, min(within, band.length - 1)), count - 1)
    }

    /// The inclusive index range covering `[from, to)` in points.
    ///
    /// This is the whole virtualisation primitive: two lookups produce the band of rows or
    /// columns a `dirtyRect` touches, whatever the scroll position.
    public func indices(fromOffset from: Double, toOffset to: Double) -> ClosedRange<Int> {
        guard count > 0 else { return 0 ... 0 }
        let first = index(atOffset: from)
        // `to` is exclusive: a rect ending exactly on a boundary must not pull in the next row.
        let last = index(atOffset: Swift.max(from, to.nextDown))
        return first ... Swift.max(first, last)
    }

    /// The first index at or after `start` that is not hidden, or `nil` when there is none.
    public func firstVisibleIndex(atOrAfter start: Int) -> Int? {
        guard count > 0 else { return nil }
        var index = Swift.max(0, start)
        while let position = bandIndex(containing: index) {
            if bands[position].size > 0 { return index }
            index = bands[position].end
        }
        return nil
    }

    /// The first index at or before `start` that is not hidden, or `nil` when there is none.
    public func lastVisibleIndex(atOrBefore start: Int) -> Int? {
        guard count > 0 else { return nil }
        var index = Swift.min(start, count - 1)
        while let position = bandIndex(containing: index) {
            if bands[position].size > 0 { return index }
            index = bands[position].start - 1
            if index < 0 { return nil }
        }
        return nil
    }
}
