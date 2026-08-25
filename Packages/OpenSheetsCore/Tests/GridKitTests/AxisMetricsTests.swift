import SheetModel
import Testing
@testable import GridKit

@Suite("Axis metrics")
struct AxisMetricsTests {
    private func metrics(
        default defaultSize: Double = 24,
        runs: [RunLengthArray<Double>.Run] = [],
        hidden: [RunLengthArray<Bool>.Run] = [],
        count: Int = 1_048_576,
        scale: Double = 1
    ) -> AxisMetrics {
        AxisMetrics(
            sizes: RunLengthArray(defaultValue: defaultSize, runs: runs),
            hidden: RunLengthArray(defaultValue: false, runs: hidden),
            count: count,
            scale: scale
        )
    }

    @Test("A uniform axis is one band whatever its length")
    func uniformAxisIsOneBand() {
        let axis = metrics()
        #expect(axis.bands.count == 1)
        #expect(axis.totalExtent == 24 * 1_048_576)
    }

    @Test("Offsets are exact at both ends and in the middle")
    func offsets() {
        let axis = metrics()
        #expect(axis.offset(ofIndex: 0) == 0)
        #expect(axis.offset(ofIndex: 1) == 24)
        #expect(axis.offset(ofIndex: 1_048_575) == 24 * 1_048_575)
        #expect(axis.offset(ofIndex: 1_048_576) == axis.totalExtent)
        // Past the end clamps rather than extrapolating: a scroll position cannot be off-sheet.
        #expect(axis.offset(ofIndex: 5_000_000) == axis.totalExtent)
        #expect(axis.offset(ofIndex: -3) == 0)
    }

    @Test("Custom bands split and merge correctly")
    func customBands() {
        let axis = metrics(runs: [
            .init(range: 10 ... 19, value: 50),
            .init(range: 20 ... 29, value: 50),
            .init(range: 100 ... 100, value: 8),
        ], count: 1000)
        // The two adjacent 50pt runs merge into one band; the default gaps are bands too.
        #expect(axis.size(ofIndex: 9) == 24)
        #expect(axis.size(ofIndex: 10) == 50)
        #expect(axis.size(ofIndex: 29) == 50)
        #expect(axis.size(ofIndex: 30) == 24)
        #expect(axis.size(ofIndex: 100) == 8)
        #expect(axis.offset(ofIndex: 10) == 240)
        #expect(axis.offset(ofIndex: 30) == 1240)
        // 1000 rows at 24pt = 24,000, less twenty rows replaced by 50pt (+520) and one by 8pt (−16).
        #expect(axis.totalExtent == 24_504)
    }

    @Test("Hidden indices occupy no space and are never hit")
    func hiddenIndices() {
        let axis = metrics(hidden: [.init(range: 5 ... 7, value: true)], count: 100)
        #expect(axis.size(ofIndex: 6) == 0)
        #expect(axis.isHidden(6))
        #expect(axis.offset(ofIndex: 5) == axis.offset(ofIndex: 8))
        // A point exactly on the collapsed band belongs to the next visible index.
        #expect(axis.index(atOffset: axis.offset(ofIndex: 5)) == 8)
        #expect(axis.firstVisibleIndex(atOrAfter: 5) == 8)
        #expect(axis.lastVisibleIndex(atOrBefore: 7) == 4)
        #expect(axis.totalExtent == 24 * 97)
    }

    @Test("index(atOffset:) inverts offset(ofIndex:) across the whole axis", arguments: [
        0, 1, 42, 999, 100_000, 524_288, 1_048_574, 1_048_575,
    ])
    func roundTrip(index: Int) {
        let axis = metrics(runs: [
            .init(range: 100 ... 200, value: 40),
            .init(range: 900_000 ... 900_010, value: 7),
        ])
        let offset = axis.offset(ofIndex: index)
        #expect(axis.index(atOffset: offset) == index)
        #expect(axis.index(atOffset: offset + axis.size(ofIndex: index) / 2) == index)
    }

    @Test("Zoom scales every band")
    func zoom() {
        let axis = metrics(runs: [.init(range: 3 ... 3, value: 100)], count: 50, scale: 2)
        #expect(axis.size(ofIndex: 0) == 48)
        #expect(axis.size(ofIndex: 3) == 200)
        #expect(axis.offset(ofIndex: 4) == 48 * 3 + 200)
    }

    @Test("Visible index ranges do not pull in the row after a boundary")
    func visibleRange() {
        let axis = metrics(count: 1000)
        let range = axis.indices(fromOffset: 0, toOffset: 240)
        #expect(range == 0 ... 9)
        let shifted = axis.indices(fromOffset: 24, toOffset: 48)
        #expect(shifted == 1 ... 1)
    }

    // MARK: - The constant-cost claim

    @Test("Scrolling to the last row costs exactly what scrolling to the first row costs")
    func lookupCountIsIndependentOfScrollPosition() {
        let axis = metrics(runs: (0 ..< 200).map {
            .init(range: ($0 * 500) ... ($0 * 500 + 10), value: Double(20 + $0 % 7))
        })

        func lookups(at offset: Double) -> Int {
            GridWork.measured {
                let index = axis.index(atOffset: offset)
                _ = axis.offset(ofIndex: index)
                _ = axis.indices(fromOffset: offset, toOffset: offset + 900)
                return GridInstrumentation.snapshot().axisLookups
            }
        }

        let atTop = lookups(at: 0)
        let atMiddle = lookups(at: axis.totalExtent / 2)
        let atBottom = lookups(at: axis.totalExtent - 900)
        #expect(atTop == atMiddle)
        #expect(atMiddle == atBottom)
        // Four lookups: the explicit two, plus the two inside `indices(fromOffset:toOffset:)`.
        #expect(atTop == 4)
    }

    @Test("Band count tracks distinct sizes, not sheet length")
    func bandCountIsBounded() {
        let axis = metrics(runs: [
            .init(range: 10 ... 20, value: 40),
            .init(range: 21 ... 30, value: 40),
            .init(range: 31 ... 40, value: 40),
        ])
        // default | 40pt | default — three bands for a 1,048,576-row axis.
        #expect(axis.bands.count == 3)
    }

    @Test("A zero-length axis answers without trapping")
    func emptyAxis() {
        let axis = metrics(count: 0)
        #expect(axis.totalExtent == 0)
        #expect(axis.index(atOffset: 100) == 0)
        #expect(axis.offset(ofIndex: 5) == 0)
        #expect(axis.firstVisibleIndex(atOrAfter: 0) == nil)
    }

    @Test("An entirely hidden axis has no visible index")
    func fullyHiddenAxis() {
        let axis = metrics(hidden: [.init(range: 0 ... 99, value: true)], count: 100)
        #expect(axis.totalExtent == 0)
        #expect(axis.firstVisibleIndex(atOrAfter: 0) == nil)
        #expect(axis.lastVisibleIndex(atOrBefore: 99) == nil)
    }
}
