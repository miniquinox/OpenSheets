import Foundation
import SheetModel
import Testing
@testable import TestSupport

/// The heavy benchmark lane. **Off unless `OPENSHEETS_BENCH=1`**, which `Scripts/bench.sh` sets.
///
/// It is off by default because six other agents run `swift test` all day and none of them should
/// pay for a million-cell build to find out whether their parser compiles. `Scripts/bench.sh`
/// turns it on, scrapes the `@@OPENSHEETS_BENCH@@` lines every `Benchmark.record` prints, and
/// writes `docs/perf/latest.json`.
///
/// **These are the metrics that can be measured today.** Most of PLAN.md §10.6 needs code that
/// does not exist yet — an xlsx reader, a grid, a formula engine — so those budgets live in
/// `docs/perf/budgets.json` and are reported as `blocked` until the agent who owns them emits a
/// sample with the matching id. Adding one is a single `Benchmark.record` call from any test
/// target; nothing here needs to change.
///
/// Serialised because several of these read process-wide memory counters.
@Suite("Benchmarks", .serialized, .enabled(if: Benchmark.isEnabled), .timeLimit(.minutes(10)))
struct Benchmarks {
    /// Everything that needs a million cells, in one test, because building them twice is two
    /// minutes of a CI job spent proving nothing.
    @Test("a million-cell workbook: build cost, residency, and a windowed read out of it")
    func millionCells() throws {
        let before = WorkCounters.residentBytes()
        var store = try SyntheticWorkbook.cellStore(rows: 1000, cols: 1000, shape: .numbersOnly)
        let after = WorkCounters.residentBytes()
        #expect(store.count == 1_000_000)

        // Five timed builds, reporting the fastest. Measured at one sample this metric swung
        // 167% run to run on a loaded machine; min-of-five brings it inside 15%. The cost is
        // four extra builds, about a third of a second.
        let build = PerfGuard.measure(
            id: "model.cellstore.build.1m.seconds", budget: .seconds(4), iterations: 5, warmups: 0
        ) {
            store = (try? SyntheticWorkbook.cellStore(rows: 1000, cols: 1000, shape: .numbersOnly)) ?? CellStore()
        }
        #expect(build.best > 0)
        #expect(store.count == 1_000_000)

        Benchmark.record(
            id: "model.cellstore.rss.1m.bytes",
            value: Double(after - before),
            unit: .bytes,
            budget: 600 * 1024 * 1024,
            note: "the model's share of §10.6's 600 MB ceiling; the reader's own buffers are extra"
        )
        Benchmark.record(
            id: "model.cellstore.bytesPerCell",
            value: Double(after - before) / 1_000_000,
            unit: .bytes,
            budget: 128,
            note: "Cell is ~48 bytes; anything near 128 means the store is the overhead"
        )

        // A 50 × 50 window is roughly one screen of cells at ProMotion densities, so this is the
        // per-frame read the grid does while flinging.
        let window = CellRange(rows: 500 ... 549, columns: 500 ... 549)
        _ = store.cells(in: window)
        let timing = PerfGuard.measure(
            id: "model.cellstore.window50x50.seconds", budget: .milliseconds(1), iterations: 50
        ) {
            MachineCalibration.blackHole(store.cells(in: window))
        }
        #expect(timing.best > 0)

        var visited = 0
        let (_, allocations) = WorkCounters.measuringAllocations {
            store.forEachCell(in: window) { _, _ in visited += 1 }
        }
        #expect(visited == 2500)
        Benchmark.record(
            id: "model.cellstore.window50x50.allocations",
            value: Double(allocations.netAllocations),
            unit: .count,
            budget: 64,
            note: "the allocation-free walk must not allocate per cell — a work metric, load-proof"
        )
    }

    @Test("a hundred thousand cells: build, diff, and the work the diff actually does")
    func hundredThousandCellDiff() throws {
        let original = try SyntheticWorkbook.generate(rows: 1000, cols: 100, shape: .numbersOnly)
        let changed = try SyntheticWorkbook.perturb(original, changedCells: 500)
        let left = original.sheets[0]
        let right = changed.sheets[0]
        guard let used = left.usedRange else { return }

        var changes: [CellChange] = []
        // PLAN.md §10.6: external change → diff shown, under a second at 100k cells.
        let timing = PerfGuard.measure(
            id: "model.diff.100k.seconds", budget: .seconds(1), iterations: 12
        ) {
            changes.removeAll(keepingCapacity: true)
            for ref in used {
                if let change = CellChange.classify(ref: ref, before: left.cells[ref], after: right.cells[ref]) {
                    changes.append(change)
                }
            }
        }
        #expect(timing.best > 0)
        #expect(!changes.isEmpty)

        Benchmark.record(
            id: "model.diff.100k.changes",
            value: Double(changes.count),
            unit: .count,
            note: "how many cells the perturbation actually moved — a determinism canary"
        )
        Benchmark.record(
            id: "model.diff.100k.visited",
            value: Double(used.cellCount),
            unit: .count,
            budget: 200_000,
            note: "a diff that walks the rectangle rather than the populated rows costs this many visits"
        )
    }

    @Test("A1 notation, both directions, at the rate a 1M-cell parse needs")
    func a1Throughput() {
        let references = (0 ..< 1000).map { CellRef(row: $0, column: $0 % 700) }
        let strings = references.map(\.a1String)

        var parsed = 0
        PerfGuard.measure(id: "model.a1.parse.1m.seconds", budget: .milliseconds(400), iterations: 30) {
            parsed = 0
            for _ in 0 ..< 1000 {
                for text in strings where CellRef(a1: text) != nil { parsed += 1 }
            }
        }
        #expect(parsed == 1_000_000)

        var buffer: [UInt8] = []
        buffer.reserveCapacity(16_000)
        PerfGuard.measure(id: "model.a1.emit.1m.seconds", budget: .milliseconds(400), iterations: 25) {
            for _ in 0 ..< 1000 {
                buffer.removeAll(keepingCapacity: true)
                for ref in references { ref.appendA1(to: &buffer) }
            }
        }
        #expect(!buffer.isEmpty)
    }

    @Test("scroll geometry stays bound by the number of runs, not the number of rows")
    func scrollGeometry() {
        var heights = RunLengthArray(defaultValue: 24.0)
        for band in 0 ..< 100 {
            heights.setValue(Double(30 + band), in: (band * 1000) ... (band * 1000 + 10))
        }

        var index = 0
        // 10,000 round-trips is roughly ten seconds of flinging at 120 Hz.
        PerfGuard.measure(id: "model.runlength.geometry.10k.seconds", budget: .milliseconds(60), iterations: 25) {
            for step in 0 ..< 10_000 {
                let offset = heights.offset(ofIndex: 1_048_575 - step)
                index = heights.index(atOffset: offset, limit: Limits.rowCount)
            }
        }
        #expect(index > 0)

        Benchmark.record(
            id: "model.runlength.runs",
            value: Double(heights.runCount),
            unit: .count,
            budget: 100,
            note: "the cost above is bound by this, not by the sheet's 1,048,576 rows"
        )
    }

    @Test("a sparse million-cell sheet does not cost what a dense one does")
    func sparseResidency() throws {
        // No warm-up. A discarded first generation frees pages the second one then reuses, so
        // the measured delta came out *negative* — an RSS delta only means anything on the first
        // touch. Declared `"noisy": true` in budgets.json instead: it is a real number with a
        // real ±10% jitter, gated at the timing tolerance rather than the strict one.
        let before = WorkCounters.residentBytes()
        let workbook = try SyntheticWorkbook.sparse(cellCount: 100_000)
        let after = WorkCounters.residentBytes()
        #expect(workbook.sheets[0].cells.count == 100_000)

        Benchmark.record(
            id: "model.cellstore.sparse.100k.bytes",
            value: Double(after - before),
            unit: .bytes,
            budget: 64 * 1024 * 1024,
            note: "100k cells scattered over the whole grid: cost must track population, not bounding box"
        )

        var found = 0
        let timing = PerfGuard.measure(
            id: "model.cellstore.sparseScan.seconds", budget: .milliseconds(50), iterations: 40
        ) {
            found = workbook.sheets[0].cells.cells(in: .entireSheet).count
        }
        #expect(found == 100_000)
        #expect(timing.best > 0)
    }

    @Test("style interning stays cheap as the table grows")
    func styleInterning() {
        var table = StyleTable()
        PerfGuard.measure(id: "model.styles.intern.10k.seconds", budget: .milliseconds(200), iterations: 10) {
            table = StyleTable()
            for index in 0 ..< 10_000 {
                _ = table.intern(CellStyle(numberFormatID: Int32(index % 400)))
            }
        }
        #expect(table.count == 400, "400 distinct format ids, of which id 0 is the default already in the table")
    }

    @Test("the machine this run happened on is recorded alongside the numbers")
    func machineContext() {
        let load = MachineLoad.sample()
        Benchmark.record(
            id: "machine.calibration.seconds",
            value: MachineCalibration.measure(iterations: 15),
            unit: .seconds,
            note: "the fixed CPU kernel; divide by the baseline's value to normalise every other metric"
        )
        Benchmark.record(id: "machine.load.normalized", value: load.normalized, unit: .ratio, note: load.summary)
        Benchmark.record(id: "machine.cores", value: Double(load.activeProcessorCount), unit: .count)
        #expect(load.activeProcessorCount > 0)
    }
}
