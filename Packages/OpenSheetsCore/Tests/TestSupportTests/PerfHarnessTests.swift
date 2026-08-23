import Foundation
import SheetModel
import Testing
@testable import TestSupport

/// Serialised because ``Benchmark`` collects into process-wide state and ``WorkCounters``
/// reads process-wide heap statistics. Two of these running at once would measure each other.
@Suite("Performance harness", .serialized)
struct PerfHarnessTests {
    @Test("resident size is a plausible number and the peak never trails it")
    func residentSize() {
        let resident = WorkCounters.residentBytes()
        #expect(resident > 1024 * 1024, "a Swift test process is never smaller than a megabyte")
        #expect(WorkCounters.peakResidentBytes() >= resident)
    }

    @Test("allocation counting separates an allocating body from a non-allocating one")
    func allocationCounting() {
        // `mstats()` is process-wide, and Swift Testing runs other suites in this process at the
        // same time — a suite that frees a few hundred blocks mid-measurement makes the delta
        // negative. Measured once at 500 allocations this test flaked exactly that way. So:
        // a signal two orders of magnitude above the observed noise, and best-of-three.
        // `Scripts/bench.sh` sidesteps the problem entirely by running `--no-parallel`.
        var allocating = WorkCounters.AllocationReport(netAllocations: 0, netBytes: 0, residentDelta: 0)
        var quiet = allocating
        var kept = 0
        for _ in 0 ..< 3 {
            let (arrays, report) = WorkCounters.measuringAllocations { () -> [[Int]] in
                (0 ..< 20_000).map { Array(repeating: $0, count: 8) }
            }
            kept = arrays.count
            if report.netAllocations > allocating.netAllocations { allocating = report }

            let (sum, idle) = WorkCounters.measuringAllocations { (0 ..< 1000).reduce(0, +) }
            #expect(sum == 499_500)
            if idle.netAllocations > quiet.netAllocations { quiet = idle }
        }

        #expect(kept == 20_000)
        #expect(allocating.netAllocations > 10_000, "20,000 arrays cannot be free")
        #expect(allocating.netBytes > 0)
        #expect(allocating.description.contains("blocks"))
        #expect(quiet.netAllocations < allocating.netAllocations, "summing a range must not allocate per element")
    }

    @Test("byte counts read the way a human reads them")
    func byteFormatting() {
        #expect(ByteCount.describe(512) == "512 B")
        #expect(ByteCount.describe(2048) == "2 KB")
        #expect(ByteCount.describe(3 * 1024 * 1024) == "3.0 MB")
        #expect(ByteCount.describe(-2 * 1024 * 1024) == "-2.0 MB")
    }

    @Test("the machine load sample is self-consistent")
    func machineLoad() {
        let load = MachineLoad.sample()
        #expect(load.activeProcessorCount > 0)
        #expect(load.loadAverage1 >= 0)
        #expect(load.normalized >= 0)
        #expect(load.recommendedSlack >= 1)
        #expect(!load.summary.isEmpty)
        // Whatever it is, the state and the slack must agree.
        switch load.state {
        case .idle: #expect(load.recommendedSlack == 1.0)
        case .busy: #expect(load.recommendedSlack > 1.0)
        case .overloaded: #expect(!load.permitsTimingAssertions)
        }
    }

    @Test("load classification follows the thresholds it documents")
    func loadThresholds() {
        func load(_ average: Double, cores: Int = 10, thermal: String = "nominal") -> MachineLoad {
            MachineLoad(
                loadAverage1: average, loadAverage5: average, loadAverage15: average,
                activeProcessorCount: cores, thermalState: thermal, isLowPowerMode: false
            )
        }
        #expect(load(1).state == .idle)
        #expect(load(5).state == .busy)
        #expect(load(12).state == .overloaded)
        // Thermal throttling is a load even when nothing is runnable.
        #expect(load(0, thermal: "critical").state == .overloaded)
    }

    @Test("the calibration kernel is stable enough to divide by")
    func calibration() {
        let first = MachineCalibration.measure(iterations: 3)
        let second = MachineCalibration.measure(iterations: 3)
        #expect(first > 0)
        #expect(second > 0)
        // Min-of-three twice: on a machine so loaded that these differ by more than 4× there is
        // nothing to measure anyway, and that is precisely when the harness downgrades.
        let load = MachineLoad.sample()
        let ratio = max(first, second) / min(first, second)
        if load.permitsTimingAssertions {
            #expect(ratio < 4, "calibration spread \(ratio)× — machine load \(load.summary)")
        }

        #expect(MachineCalibration.scalingFactor(reference: 1e9) == 1, "a fast machine must not tighten a budget")
        #expect(MachineCalibration.scalingFactor(reference: 1e-9) > 1)
    }

    @Test("recording a sample emits one marker line and keeps it")
    func recording() {
        Benchmark.reset()
        Benchmark.record(id: "test.metric", value: 1.5, unit: .seconds, budget: 2.0)
        let recorded = Benchmark.recorded
        #expect(recorded.count == 1)
        #expect(recorded[0].id == "test.metric")
        #expect(recorded[0].withinBudget == true)
        #expect(recorded[0].normalizedLoad != nil)
        Benchmark.reset()
    }

    @Test("a sample round-trips through the JSON the harness scrapes")
    func sampleCoding() throws {
        let sample = BenchmarkSample(
            id: "xlsx.read.100k.seconds", value: 0.42, unit: .seconds, budget: 0.8,
            status: .measured, samples: 5, machineFactor: 1.2, normalizedLoad: 0.3, note: "hello"
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BenchmarkSample.self, from: data)
        #expect(decoded == sample)
    }

    @Test("a blocked metric stays in the report instead of vanishing from it")
    func blockedMetric() {
        Benchmark.reset()
        Benchmark.blocked(id: "xlsx.read.1m.seconds", unit: .seconds, budget: 4.0, blockedOn: "SheetFormat (A1)")
        let sample = Benchmark.recorded.first
        #expect(sample?.status == .blocked)
        #expect(sample?.budget == 4.0)
        #expect(sample?.note?.contains("SheetFormat") == true)
        #expect(sample?.value.isNaN == true)
        Benchmark.reset()
    }

    @Test("units know which direction is better")
    func unitDirection() {
        #expect(BenchmarkUnit.seconds.lowerIsBetter)
        #expect(BenchmarkUnit.bytes.lowerIsBetter)
        #expect(!BenchmarkUnit.ratio.lowerIsBetter)
        #expect(!BenchmarkUnit.rate.lowerIsBetter)

        let hitRate = BenchmarkSample(id: "cache.hitRate", value: 0.95, unit: .ratio, budget: 0.9)
        #expect(hitRate.withinBudget == true)
        let poorRate = BenchmarkSample(id: "cache.hitRate", value: 0.5, unit: .ratio, budget: 0.9)
        #expect(poorRate.withinBudget == false)
    }

    @Test("measure reports the fastest run, not the average of a contended one")
    func minimumOfN() {
        Benchmark.reset()
        var call = 0
        let timing = PerfGuard.measure(id: "test.minOfN", budget: .seconds(10), iterations: 4, warmups: 1) {
            call += 1
            // One deliberately slow run, standing in for a scheduler hiccup.
            let spins = call == 3 ? 4_000_000 : 200_000
            var accumulator: UInt64 = 0
            for index in 0 ..< spins { accumulator = accumulator &+ UInt64(index) }
            MachineCalibration.blackHole(accumulator)
        }
        #expect(call == 5, "one warm-up plus four timed runs")
        #expect(timing.samples == 4)
        #expect(timing.best <= timing.worst)
        #expect(timing.best < timing.worst, "the slow run must not drag the reported number down with it")
        #expect(timing.passed)
        Benchmark.reset()
    }

    @Test("the budget is scaled by the debug penalty and the machine speed")
    func budgetScaling() {
        Benchmark.reset()
        let timing = PerfGuard.measure(
            id: "test.scaling", budget: .milliseconds(100), iterations: 1, warmups: 0, machineFactor: 2
        ) {}
        let baseline = 0.1 * PerfGuard.debugSlack * 2
        #expect(timing.effectiveBudget != nil)
        if let effective = timing.effectiveBudget {
            // Exactly the written budget times the debug penalty, the machine factor, and the
            // machine's own load slack. Asserted against the slack the run actually saw rather
            // than a hard-coded ceiling — low power mode multiplies it again, and hard-coding
            // "at most 3×" is how this test failed the first time.
            #expect(abs(effective - baseline * timing.load.recommendedSlack) < 1e-9)
            #expect(effective >= baseline)
        }
        #expect(timing.summary.contains("test.scaling"))
        Benchmark.reset()
    }

    @Test("a run on a loaded machine is marked degraded rather than failed")
    func degradedStatus() {
        Benchmark.reset()
        let timing = PerfGuard.measure(id: "test.status", budget: .seconds(1), iterations: 1, warmups: 0) {}
        let load = MachineLoad.sample()
        #expect(timing.status == (load.permitsTimingAssertions ? .measured : .degraded))
        #expect(Benchmark.recorded.first?.status == timing.status)
        Benchmark.reset()
    }

    @Test("a work-done assertion passes or fails on the number, with no clock involved")
    func workAssertions() {
        Benchmark.reset()
        #expect(PerfGuard.expectWork("test.syscalls", value: 3, atMost: 10, unit: .count))
        let sample = Benchmark.recorded.first
        #expect(sample?.unit == .count)
        #expect(sample?.budget == 10)
        Benchmark.reset()
    }

    @Test("the benchmark lane is off unless it is asked for")
    func laneIsGated() {
        #expect(Benchmark.isEnabled == (ProcessInfo.processInfo.environment["OPENSHEETS_BENCH"] == "1"))
        #expect(Benchmark.marker == "@@OPENSHEETS_BENCH@@")
    }
}
