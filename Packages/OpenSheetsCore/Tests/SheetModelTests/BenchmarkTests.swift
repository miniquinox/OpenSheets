import Foundation
@testable import SheetModel
import Testing

/// The performance floor `CellStore` has to hold, from A0's acceptance criteria.
///
/// These are budgets, not micro-benchmarks: they exist to catch a representation change that
/// quietly turns an O(log n) lookup into a scan. The numbers are generous enough not to flake
/// on a loaded machine and tight enough that a real regression trips them.
///
/// **Debug builds get a slacker budget.** `swift test` is unoptimised by default and a
/// bounds-checked, non-inlined build runs several times slower than the shipping one. The
/// release budgets are the ones in the brief; the debug multiplier is stated rather than
/// hidden, so nobody reads a green debug run as proof the release budget holds. CI runs both.
@Suite("CellStore performance", .timeLimit(.minutes(2)))
struct BenchmarkTests {
    #if DEBUG
        /// Unoptimised builds pay for bounds checks, retain/release, and no inlining.
        static let buildSlack = 6.0
        static let configuration = "debug"
    #else
        static let buildSlack = 1.0
        static let configuration = "release"
    #endif

    /// Build slack, widened when the machine is oversubscribed.
    ///
    /// These budgets are calibrated on an idle Mac. Run them while several other builds are
    /// competing for the same cores and they measure the scheduler instead of the code — this
    /// suite sat at 100–112% of budget on three separate tests during Wave 1, every one of them a
    /// flake rather than a regression. A flaky gate gets ignored, and an ignored gate is worse
    /// than no gate at all (see `docs/agents/WAVE-1-ADDENDUM.md` §8).
    ///
    /// So: scale linearly with overload, capped at 4×. A real regression is an order of
    /// magnitude and still trips this; scheduler noise does not. Where a claim can be stated as a
    /// ratio or a counter instead, it is — see ``metadataIsConstantTime`` — and that is always
    /// preferable to a stopwatch. This exists for the cases where throughput really is the claim.
    /// Sampled per test, deliberately — **not** a `static let`.
    ///
    /// A one-shot `static let` is evaluated at first access, which is early in the run while the
    /// machine is still idle. Seventy seconds later the test run has saturated its own cores and
    /// the cached multiplier is stale, which is exactly how this suite failed again after the
    /// first attempt at fixing it. `getloadavg` is one syscall per test; read it fresh.
    static var slack: Double {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var averages = [Double](repeating: 0, count: 1)
        guard getloadavg(&averages, 1) == 1, cores > 0, averages[0] > 0 else { return buildSlack }
        return buildSlack * min(max(1.0, averages[0] / cores), 4.0)
    }

    /// Prints the load a budget was set against, so a wide budget is never silently wide.
    private static func noteLoad() {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        var averages = [Double](repeating: 0, count: 1)
        guard getloadavg(&averages, 1) == 1, cores > 0, averages[0] / cores > 1.05 else { return }
        print(String(
            format: "  [perf/%@] loaded: %.1f/%.0f cores — budget widened %.1fx",
            configuration, averages[0], cores, min(averages[0] / cores, 4.0)
        ))
    }

    private static func report(_ label: String, _ elapsed: Duration, budget: Duration) {
        noteLoad()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let budgetSeconds = Double(budget.components.seconds) + Double(budget.components.attoseconds) / 1e18
        print(String(
            format: "  [perf/%@] %@: %.4fs (budget %.4fs, %.0f%% used)",
            configuration, label, seconds, budgetSeconds, seconds / budgetSeconds * 100
        ))
    }

    /// A 1,000 × 1,000 workbook — a million cells in the shape a real sheet has, rather than a
    /// million single-cell rows, which would only exercise the dictionary.
    private static func millionCellStore() throws -> CellStore {
        var store = CellStore()
        store.reserveCapacity(rows: 1000)
        for row in 0 ..< 1000 {
            for column in 0 ..< 1000 {
                try store.setCell(.number(Double(row * 1000 + column)), at: CellRef(row: row, column: column))
            }
        }
        return store
    }

    @Test("inserting 1,000,000 cells stays under two seconds")
    func millionCellInsert() throws {
        let budget = Duration.seconds(2 * Self.slack)
        let clock = ContinuousClock()

        var store = CellStore()
        store.reserveCapacity(rows: 1000)
        let elapsed = try clock.measure {
            for row in 0 ..< 1000 {
                for column in 0 ..< 1000 {
                    try store.setCell(.number(Double(row * 1000 + column)), at: CellRef(row: row, column: column))
                }
            }
        }

        Self.report("insert 1M cells", elapsed, budget: budget)
        #expect(store.count == 1_000_000)
        #expect(store.usedRange?.a1String == "A1:ALL1000")
        #expect(elapsed < budget, "1M inserts took \(elapsed), budget \(budget)")
    }

    @Test("a 50×50 window out of 1,000,000 cells resolves in under a millisecond")
    func rectangleQueryOutOfAMillion() throws {
        let store = try Self.millionCellStore()
        let window = CellRange(rows: 500 ... 549, columns: 500 ... 549)
        #expect(window.rowCount == 50 && window.columnCount == 50)

        // One warm pass so the measurement is not paying for first-touch page faults.
        _ = store.cells(in: window)

        let budget = Duration.milliseconds(Int(1 * Self.slack))
        let clock = ContinuousClock()
        var result: [(ref: CellRef, cell: Cell)] = []
        // Averaged over 50 runs: a single sub-millisecond measurement is mostly clock noise.
        let total = clock.measure {
            for _ in 0 ..< 50 {
                result = store.cells(in: window)
            }
        }
        let perCall = total / 50

        Self.report("cells(in: 50×50) of 1M", perCall, budget: budget)
        #expect(result.count == 2500)
        #expect(perCall < budget, "a 50×50 query took \(perCall), budget \(budget)")
    }

    @Test("the allocation-free walk of the same window is no slower")
    func forEachOverTheSameWindow() throws {
        let store = try Self.millionCellStore()
        let window = CellRange(rows: 500 ... 549, columns: 500 ... 549)
        store.forEachCell(in: window) { _, _ in }

        let budget = Duration.milliseconds(Int(1 * Self.slack))
        let clock = ContinuousClock()
        var seen = 0
        let total = clock.measure {
            for _ in 0 ..< 50 {
                seen = 0
                store.forEachCell(in: window) { _, _ in seen += 1 }
            }
        }
        let perCall = total / 50

        Self.report("forEachCell(in: 50×50) of 1M", perCall, budget: budget)
        #expect(seen == 2500)
        #expect(perCall < budget)
    }

    @Test("a rectangle query does not scan rows it will not return")
    func queryCostTracksResultNotRectangle() throws {
        // Three populated rows, a query spanning the whole sheet. If the cost were driven by
        // the rectangle rather than the data, this would walk a million rows and take seconds.
        var sparse = CellStore()
        try sparse.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try sparse.setCell(.number(2), at: CellRef(row: 500_000, column: 5))
        try sparse.setCell(.number(3), at: CellRef(row: 1_048_575, column: 16_383))

        let budget = Duration.milliseconds(Int(5 * Self.slack))
        let clock = ContinuousClock()
        var found = 0
        let elapsed = clock.measure {
            for _ in 0 ..< 100 {
                found = sparse.cells(in: .entireSheet).count
            }
        }
        let perCall = elapsed / 100

        Self.report("cells(in: entireSheet) of 3", perCall, budget: budget)
        #expect(found == 3)
        #expect(perCall < budget)
    }

    @Test("usedRange and count stay constant-time on a million cells")
    func metadataIsConstantTime() throws {
        // The claim is O(1) in cell count, and a ratio states that far better than a stopwatch.
        // An absolute budget here measured the machine, not the algorithm: it sat at 112% of
        // budget while seven other builds were running, which is a flake, not a regression.
        // Both halves below run under identical load, so the ratio cancels it out.
        let big = try Self.millionCellStore()
        var small = CellStore()
        for row in 0 ..< 3 { try small.setCell(Cell.number(Double(row)), at: CellRef(row: row, column: 0)) }

        func timeReads(_ store: CellStore) -> Double {
            var range: CellRange?
            var count = 0
            let elapsed = ContinuousClock().measure {
                for _ in 0 ..< 100_000 {
                    range = store.usedRange
                    count = store.count
                }
            }
            precondition(range != nil && count > 0)
            return Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
        }

        _ = timeReads(small) // warm
        let smallSeconds = timeReads(small)
        let bigSeconds = timeReads(big)
        let ratio = bigSeconds / max(smallSeconds, 1e-9)

        print(String(format: "  [perf/%@] usedRange+count 1M vs 3 cells: ratio %.2f", Self.configuration, ratio))
        #expect(big.count == 1_000_000)
        // O(1) gives ~1. A linear scan over 1M cells instead of 3 would give six figures.
        #expect(ratio < 4, "usedRange/count scale with cell count (ratio \(ratio))")
    }

    @Test("scrolling geometry does not walk a million rows")
    func runLengthGeometryIsRunBound() {
        var heights = RunLengthArray(defaultValue: 24.0)
        for band in 0 ..< 100 {
            heights.setValue(Double(30 + band), in: (band * 1000) ... (band * 1000 + 10))
        }
        #expect(heights.runCount == 100)

        // The claim is that this is bound by the 100 runs, not by the 1,048,576 rows. A ratio
        // across two very different index positions states exactly that and is immune to machine
        // load; an absolute budget here sat at 103% while other builds ran, which measured the
        // scheduler rather than the data structure.
        func timeRoundTrips(startingAt row: Int) -> Double {
            var index = 0
            let elapsed = ContinuousClock().measure {
                for step in 0 ..< 10_000 {
                    let offset = heights.offset(ofIndex: row - step)
                    index = heights.index(atOffset: offset, limit: Limits.rowCount)
                }
            }
            precondition(index >= 0)
            return Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds)
        }

        // Both positions sit PAST every run, so both traverse all 100 of them and the run-prefix
        // length cancels. What differs is the row index — 99,010 against 1,048,575, a 10× spread
        // over roughly a million rows. That isolates the actual claim.
        //
        // Comparing against a row *inside* the bands would not: row 20,000 sums only ~20 runs to
        // row 1,048,575's 100, so it measures prefix length and reports ~5× on a perfectly
        // run-bound implementation. Measured, and it is why this comparison is written this way.
        let lastRunEnd = 99 * 1000 + 10
        _ = timeRoundTrips(startingAt: lastRunEnd) // warm
        let justPastRuns = timeRoundTrips(startingAt: lastRunEnd)
        let farPastRuns = timeRoundTrips(startingAt: 1_048_575)
        let ratio = farPastRuns / max(justPastRuns, 1e-9)

        print(String(format: "  [perf/%@] offset+index at row 1M vs row 99k: ratio %.2f", Self.configuration, ratio))
        // Run-bound gives ~1. Index-bound would be ~10× here, and four orders of magnitude
        // against row 0.
        #expect(ratio < 4, "run-length geometry scales with row index (ratio \(ratio))")
    }

    @Test("A1 parsing of a million references stays off the critical path")
    func a1ParsingThroughput() {
        // The reader does this once per cell on a 1M-cell workbook, so it has to be cheap
        // relative to the XML parse around it.
        let references = (0 ..< 1000).map { CellRef(row: $0, column: $0 % 700).a1String }
        let budget = Duration.milliseconds(Int(400 * Self.slack))
        let clock = ContinuousClock()

        var parsed = 0
        let elapsed = clock.measure {
            for _ in 0 ..< 1000 {
                for text in references where CellRef(a1: text) != nil {
                    parsed += 1
                }
            }
        }

        Self.report("parse 1M A1 references", elapsed, budget: budget)
        #expect(parsed == 1_000_000)
        #expect(elapsed < budget)
    }

    @Test("emitting a million references into a byte buffer allocates nothing per cell")
    func a1EmissionThroughput() {
        let references = (0 ..< 1000).map { CellRef(row: $0, column: $0 % 700) }
        let budget = Duration.milliseconds(Int(400 * Self.slack))
        let clock = ContinuousClock()

        var buffer: [UInt8] = []
        buffer.reserveCapacity(16_000)
        let reservedCapacity = buffer.capacity
        let elapsed = clock.measure {
            for _ in 0 ..< 1000 {
                buffer.removeAll(keepingCapacity: true)
                for ref in references {
                    ref.appendA1(to: &buffer)
                }
            }
        }

        Self.report("emit 1M A1 references", elapsed, budget: budget)
        #expect(!buffer.isEmpty)
        // The claim in this test's name is about allocation, so assert it directly: a buffer that
        // never outgrows its reservation never reallocated, which is what "nothing per cell"
        // means. This half holds under any load, in any build configuration.
        #expect(buffer.capacity == reservedCapacity, "appendA1 grew the buffer — it allocates per cell")
        #expect(elapsed < budget)
    }
}
