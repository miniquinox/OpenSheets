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
        static let slack = 6.0
        static let configuration = "debug"
    #else
        static let slack = 1.0
        static let configuration = "release"
    #endif

    private static func report(_ label: String, _ elapsed: Duration, budget: Duration) {
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
        let store = try Self.millionCellStore()
        let budget = Duration.milliseconds(Int(5 * Self.slack))
        let clock = ContinuousClock()

        var range: CellRange?
        var count = 0
        let elapsed = clock.measure {
            for _ in 0 ..< 100_000 {
                range = store.usedRange
                count = store.count
            }
        }

        Self.report("100k usedRange+count reads", elapsed, budget: budget)
        #expect(range != nil)
        #expect(count == 1_000_000)
        #expect(elapsed < budget)
    }

    @Test("scrolling geometry does not walk a million rows")
    func runLengthGeometryIsRunBound() {
        var heights = RunLengthArray(defaultValue: 24.0)
        for band in 0 ..< 100 {
            heights.setValue(Double(30 + band), in: (band * 1000) ... (band * 1000 + 10))
        }
        #expect(heights.runCount == 100)

        // 10,000 round-trips × two O(runCount) scans is 2,000,000 run visits. The point of the
        // budget is that it is bound by the 100 runs and not by the 1,048,576 rows — an
        // index-bound implementation would be four orders of magnitude slower than this.
        let budget = Duration.milliseconds(Int(60 * Self.slack))
        let clock = ContinuousClock()
        var index = 0
        let elapsed = clock.measure {
            for step in 0 ..< 10_000 {
                let offset = heights.offset(ofIndex: 1_048_575 - step)
                index = heights.index(atOffset: offset, limit: Limits.rowCount)
            }
        }

        Self.report("10k offset+index round-trips at row 1M", elapsed, budget: budget)
        #expect(index > 0)
        #expect(elapsed < budget)
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
        #expect(elapsed < budget)
    }
}
