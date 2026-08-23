import CoreGraphics
import Foundation
import SheetModel
import Testing
@testable import GridKit

/// The gates that hold whatever else changes.
///
/// # Two kinds of assertion, on purpose
///
/// Seven agents build on this machine at once, and the Wave 1 addendum §8 is explicit that a
/// wall-clock assertion flakes under that load. So the assertions that always run measure **work
/// done** — axis lookups per frame, lines shaped per frame, cells visited, resident bytes — which
/// is both what actually determines the frame time and what stays true on a busy machine.
///
/// The wall-clock gate runs only when `GRIDKIT_PERF=1`, because a debug build is several times
/// slower than the release build the 8.3 ms budget is written for. `docs/perf/gridkit-scroll.md`
/// records a release run and says what the machine was doing.
@Suite("Performance")
@MainActor
struct GridPerformanceTests {
    /// A million populated cells: 20,000 rows × 50 columns.
    ///
    /// Built once for the whole suite. Generating it is the expensive part and is not what is
    /// being measured, and every test here wants the identical sheet anyway.
    private func millionCellWorkbook() -> Workbook {
        SharedDemoWorkbook.millionCells()
    }


    @Test("A million cells is a million cells")
    func harnessSize() {
        let workbook = millionCellWorkbook()
        #expect(workbook.cellCount == 1_000_000)
        #expect(workbook.sheets[0].usedRange?.end.row == 19_999)
        #expect(workbook.sheets[0].usedRange?.end.column == 49)
    }

    @Test("Axis lookups per frame do not depend on how far down the sheet you are")
    func lookupsAreConstant() {
        // The criterion behind "scrolling to row 1,048,576 is instant". A linear scan would make
        // the count grow with the row index; a binary search makes it depend only on how much is
        // on screen — so the comparison has to hold the screen contents equal.
        let workbook = millionCellWorkbook()
        let surface = RenderSurface(width: 1200, height: 800)
        let model = renderModel(workbook)

        func lookups(atRow row: Int) -> Int {
            let y = model.geometry.rows.offset(ofIndex: row)
            GridInstrumentation.reset()
            surface.render(model, sheetOrigin: CGPoint(x: 0, y: y))
            return GridInstrumentation.snapshot().axisLookups
        }

        // Two equally dense screenfuls, twenty thousand rows apart.
        _ = lookups(atRow: 0)
        let nearTop = lookups(atRow: 100)
        let nearTheEndOfTheData = lookups(atRow: 19_000)
        #expect(nearTop == nearTheEndOfTheData)

        // Two equally empty screenfuls, a million rows apart. The far one is where a scan would
        // show up, and it costs exactly what the near one costs.
        let justPastTheData = lookups(atRow: 25_000)
        let veryBottom = lookups(atRow: 1_048_500)
        #expect(justPastTheData == veryBottom)

        // And an empty screenful is never *more* work than a full one.
        #expect(veryBottom <= nearTop)
    }

    @Test("Drawing cost tracks the viewport, not the sheet")
    func costTracksTheViewport() {
        let small = GridDemoWorkbook.make(rows: 200, columns: 20)
        let large = millionCellWorkbook()
        let surface = RenderSurface(width: 1200, height: 800)

        func cellLookups(_ workbook: Workbook) -> Int {
            let model = renderModel(workbook)
            surface.render(model)
            GridInstrumentation.reset()
            surface.render(model)
            return GridInstrumentation.snapshot().cellLookups
        }

        let smallCost = cellLookups(small)
        let largeCost = cellLookups(large)
        // A 5,000× difference in sheet size must not show up as a difference in frame cost.
        #expect(Double(largeCost) < Double(smallCost) * 1.2)
    }

    @Test("A fling re-shapes almost nothing, because the cache holds the screen")
    func shapingIsAmortised() {
        let workbook = millionCellWorkbook()
        let model = renderModel(workbook)
        let surface = RenderSurface(width: 1200, height: 800)

        // Warm up over the region the measured pass will cover.
        for step in 0 ..< 20 {
            surface.render(model, sheetOrigin: CGPoint(x: 0, y: Double(step) * 24))
        }
        GridInstrumentation.reset()
        for step in 0 ..< 20 {
            surface.render(model, sheetOrigin: CGPoint(x: 0, y: Double(step) * 24))
        }
        let counters = GridInstrumentation.snapshot()
        #expect(counters.textCacheHits > counters.textShapes * 4)
    }

    @Test("Memory stays flat while scrolling, because every cache has a ceiling")
    func memoryIsFlat() {
        let workbook = millionCellWorkbook()
        let model = renderModel(workbook)
        let surface = RenderSurface(width: 1200, height: 800)
        let maximumY = model.geometry.rows.totalExtent - 800

        // Warm up: fill the caches to their ceilings first, so the measurement is of the steady
        // state rather than of the ramp.
        for step in 0 ..< 200 {
            surface.render(model, sheetOrigin: CGPoint(x: 0, y: Double(step) / 200 * maximumY))
        }
        let before = GridBenchmark.residentBytes()

        // Then scroll through a thousand distinct screenfuls — every one with different strings.
        for step in 0 ..< 1000 {
            surface.render(model, sheetOrigin: CGPoint(x: 0, y: Double(step) / 1000 * maximumY))
        }
        let after = GridBenchmark.residentBytes()
        // Signed. `&-` on UInt64 turns a perfectly ordinary memory reclaim into 2^44 bytes of
        // apparent growth, which then fails a `< 20` assertion with a number that reads as noise.
        let growthMB = Double(Int64(bitPattern: after) - Int64(bitPattern: before)) / (1024 * 1024)

        #expect(surface.renderer.textCache.count <= surface.renderer.textCache.capacity)
        // Twenty megabytes of headroom over a thousand screenfuls: an unbounded cache would be
        // hundreds. This is deliberately loose, because RSS on a shared machine is noisy.
        #expect(growthMB < 20, "resident memory grew by \(growthMB) MB over 1000 screenfuls")
    }

    @Test("Scrolling to the very last row draws the right cells")
    func bottomOfTheSheet() {
        let workbook = millionCellWorkbook()
        let model = renderModel(workbook)
        let lastRowTop = model.geometry.rows.offset(ofIndex: Limits.maxRow)
        let visible = model.geometry.cellRange(inSheetRect: CGRect(
            x: 0, y: lastRowTop - 400, width: 1200, height: 800
        ))
        #expect(visible.end.row == Limits.maxRow)
        // The sheet only has 20,000 populated rows, so the bottom of the sheet is empty — and
        // drawing it must cost nothing rather than crash or scan.
        let surface = RenderSurface(width: 1200, height: 800)
        GridInstrumentation.reset()
        surface.render(model, sheetOrigin: CGPoint(x: 0, y: lastRowTop - 400))
        #expect(GridInstrumentation.snapshot().cellLookups == 0)
    }

    @Test("The fling benchmark reports a full set of statistics")
    func benchmarkRuns() {
        let statistics = GridBenchmark.fling(
            workbook: millionCellWorkbook(),
            viewport: CGSize(width: 900, height: 600),
            frames: 60,
            warmUpFrames: 10
        )
        #expect(statistics.frames == 60)
        #expect(statistics.p50 > 0)
        #expect(statistics.p99 >= statistics.p50)
        #expect(statistics.worst >= statistics.p99)
        // The work-based half of the claim holds in any build configuration: lookups track the
        // number of visible cells — roughly two per cell rectangle plus one per gridline — and
        // must never track the size of the sheet. A 900 × 600 viewport holds about 300 cells.
        #expect(statistics.axisLookupsPerFrame < 2000)
        // Signed, so a reclaim reads as a negative rather than as 2^44 bytes of "growth".
        // The claim is that nothing grows without bound — not that RSS only ever rises, since
        // under pressure from other processes it legitimately falls.
        #expect(statistics.residentGrowthMB < 25)
        #expect(statistics.residentGrowthMB > -512, "underflowed, or measured a different process")
    }

    @Test(
        "120 fps sustained through a million cells",
        .enabled(if: wallClockGateEnabled)
    )
    func flingMeetsTheFrameBudget() {
        let statistics = GridBenchmark.fling(workbook: millionCellWorkbook(), frames: 900)
        #expect(statistics.p99 < 8.3, statistics.summary.asComment)
        #expect(statistics.dropped == 0, statistics.summary.asComment)
    }

    // MARK: - Helpers

    private func renderModel(_ workbook: Workbook) -> GridRenderModel {
        let sheet = workbook.sheets[0]
        return GridRenderModel(
            sheet: sheet,
            styles: workbook.styles,
            dateSystem: workbook.meta.dateSystem,
            geometry: GridGeometry(sheet: sheet),
            merges: MergeIndex(sheet.merges),
            selection: GridSelection(active: CellRef(row: 12, column: 3))
        )
    }
}

/// The million-cell workbook, built once and shared by every test in the suite.
@MainActor
enum SharedDemoWorkbook {
    private static var cached: Workbook?

    static func millionCells() -> Workbook {
        if let cached { return cached }
        let built = GridDemoWorkbook.millionCells()
        cached = built
        return built
    }
}

/// The wall-clock gate is off unless asked for: a debug build is several times slower than the
/// release build the 8.3 ms budget is written for, and this machine is running seven agents.
nonisolated let wallClockGateEnabled = ProcessInfo.processInfo.environment["GRIDKIT_PERF"] == "1"

private extension String {
    var asComment: Comment { Comment(rawValue: self) }
}
