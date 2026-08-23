//
//  WorkCounters.swift
//  TestSupport
//
//  Measuring work done rather than seconds elapsed, and noticing when the machine is busy.
//

import Darwin
import Foundation

/// Counters for the things a benchmark can measure that a loaded machine cannot distort.
///
/// Wave 1 addendum §8: seven agents build on this Mac at once, and a wall-clock assertion that
/// passes idle flakes under that load. A flaky gate gets ignored, and an ignored gate is worse
/// than no gate. So wherever a budget can be expressed as *work* — bytes resident, allocations
/// made, syscalls issued, entries visited — express it that way. Those numbers are the same on
/// an idle machine and a hammered one, and they usually say more about the bug than a duration
/// does: "the reader inflated 41 ZIP entries" is a diagnosis, "the reader took 1.9 s" is not.
public enum WorkCounters {
    // MARK: - Memory

    /// This process's resident size in bytes.
    ///
    /// The number PLAN.md §10.6's "< 600 MB RSS" budget is about. Resident rather than virtual:
    /// virtual size on macOS includes gigabytes of mapped-but-untouched address space and means
    /// nothing.
    public static func residentBytes() -> Int {
        taskInfo().map { Int($0.resident_size) } ?? 0
    }

    /// The high-water mark of ``residentBytes()`` for this process.
    ///
    /// The honest number for a peak-memory budget: a parser that briefly holds two copies of a
    /// 1M-cell workbook is over budget even if it frees one before anybody looks.
    public static func peakResidentBytes() -> Int {
        taskInfo().map { Int($0.resident_size_max) } ?? 0
    }

    private static func taskInfo() -> mach_task_basic_info? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    // MARK: - Allocations

    /// How many heap blocks this process currently holds.
    ///
    /// From `mstats()`, which is **process-wide**. Two consequences, both measured rather than
    /// assumed:
    ///
    /// - It is only meaningful as a *delta* around one piece of work, and only when nothing else
    ///   in the process is allocating. Swift Testing runs suites in parallel by default, and a
    ///   500-allocation measurement taken that way came back **negative** — another suite freed
    ///   more than this one allocated. `Scripts/bench.sh` runs `--no-parallel` for exactly this
    ///   reason; a benchmark outside that lane wants a signal well clear of the noise.
    /// - It counts blocks *still held*, not blocks *made*. Work that allocates a million
    ///   temporaries and frees them all reads as zero. That is the right number for "does this
    ///   retain per cell" and the wrong one for "how much churn does this cause".
    public static func allocationCount() -> Int {
        Int(mstats().chunks_used)
    }

    /// How many heap bytes this process currently holds. Same caveat as ``allocationCount()``.
    public static func allocatedBytes() -> Int {
        Int(mstats().bytes_used)
    }

    /// What one piece of work cost, in work rather than in time.
    public struct AllocationReport: Sendable, Hashable, Codable, CustomStringConvertible {
        /// Heap blocks still held after the work, minus those held before. Negative means the
        /// work freed more than it allocated.
        public var netAllocations: Int
        /// The same for bytes.
        public var netBytes: Int
        /// Change in resident size across the work.
        public var residentDelta: Int

        public var description: String {
            "\(netAllocations) blocks, \(ByteCount.describe(netBytes)), RSS \(ByteCount.describe(residentDelta))"
        }
    }

    /// Runs `body` and reports what it cost the heap.
    ///
    /// The result is returned alongside the report so the compiler cannot decide the work was
    /// dead and delete it — a benchmark whose body was optimised away is the classic way to
    /// measure zero and believe it.
    public static func measuringAllocations<Result>(
        _ body: () throws -> Result
    ) rethrows -> (result: Result, report: AllocationReport) {
        let beforeStats = mstats()
        let beforeResident = residentBytes()
        let result = try body()
        let afterStats = mstats()
        let afterResident = residentBytes()
        let report = AllocationReport(
            netAllocations: Int(afterStats.chunks_used) - Int(beforeStats.chunks_used),
            netBytes: Int(afterStats.bytes_used) - Int(beforeStats.bytes_used),
            residentDelta: afterResident - beforeResident
        )
        return (result, report)
    }
}

/// Byte counts spelled the way a human reads them.
public enum ByteCount {
    /// `1.4 MB`, `912 KB`, `-3.0 MB`.
    public static func describe(_ bytes: Int) -> String {
        let sign = bytes < 0 ? "-" : ""
        let magnitude = Double(abs(bytes))
        if magnitude >= 1024 * 1024 * 1024 {
            return String(format: "%@%.2f GB", sign, magnitude / (1024 * 1024 * 1024))
        }
        if magnitude >= 1024 * 1024 {
            return String(format: "%@%.1f MB", sign, magnitude / (1024 * 1024))
        }
        if magnitude >= 1024 {
            return String(format: "%@%.0f KB", sign, magnitude / 1024)
        }
        return "\(bytes) B"
    }
}

/// How busy this machine is right now, and by how much a timing budget should be widened.
///
/// Read at the start of every benchmark. The point is not precision — it is that a run taken
/// while six other agents are compiling should either compensate or say so, and must never fail
/// a build over it.
public struct MachineLoad: Sendable, Hashable, Codable {
    /// How contended the machine is.
    public enum State: String, Sendable, Hashable, Codable, CaseIterable {
        /// Under 40% of the cores are busy. Numbers taken here are worth recording as a baseline.
        case idle
        /// Busy, but a min-of-N measurement still lands close to the true cost.
        case busy
        /// More runnable work than cores. Timing assertions here are noise; measure work instead.
        case overloaded
    }

    public var loadAverage1: Double
    public var loadAverage5: Double
    public var loadAverage15: Double
    public var activeProcessorCount: Int
    /// Whether the OS says the machine is thermally throttled.
    public var thermalState: String
    public var isLowPowerMode: Bool

    /// One-minute load average per core. `1.0` means exactly saturated.
    public var normalized: Double {
        activeProcessorCount > 0 ? loadAverage1 / Double(activeProcessorCount) : loadAverage1
    }

    /// How contended the machine is, from the load average and the thermal state.
    ///
    /// Low power mode is deliberately **not** here. It throttles the CPU — measured at roughly a
    /// third of full speed on the machine this was written on — but it does so *predictably*, and
    /// treating it as "overloaded" would waive every timing gate permanently on a laptop that
    /// happens to be unplugged. It belongs in ``recommendedSlack``, which is where a known,
    /// steady slowdown belongs.
    public var state: State {
        if thermalState == "serious" || thermalState == "critical" { return .overloaded }
        if normalized >= 1.0 { return .overloaded }
        if normalized >= 0.4 { return .busy }
        return .idle
    }

    /// The multiplier a wall-clock budget should be widened by on this machine.
    ///
    /// Deliberately coarse. A precise correction would be a lie — contention is not linear — and
    /// the purpose here is only to keep a real regression detectable while keeping a busy
    /// machine from failing a build. A regression that hides inside a 3× window on a hammered
    /// machine will still show up on the next idle run, and that is an acceptable trade against
    /// a gate everyone learns to ignore.
    public var recommendedSlack: Double {
        let contention = switch state {
        case .idle: 1.0
        case .busy: 1.75
        case .overloaded: 3.0
        }
        // Low power mode is a steady, known throttle rather than contention. `MachineCalibration`
        // already measures most of it; this covers the part it does not.
        return contention * (isLowPowerMode ? 1.5 : 1)
    }

    /// Whether a timing *assertion* should run at all. A measurement is still worth recording.
    public var permitsTimingAssertions: Bool { state != .overloaded }

    /// A sample taken now.
    public static func sample() -> MachineLoad {
        var averages = [Double](repeating: 0, count: 3)
        let count = getloadavg(&averages, 3)
        let info = ProcessInfo.processInfo
        return MachineLoad(
            loadAverage1: count > 0 ? averages[0] : 0,
            loadAverage5: count > 1 ? averages[1] : 0,
            loadAverage15: count > 2 ? averages[2] : 0,
            activeProcessorCount: info.activeProcessorCount,
            thermalState: describe(info.thermalState),
            isLowPowerMode: info.isLowPowerModeEnabled
        )
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    public var summary: String {
        String(
            format: "load %.2f/%d cores (%.0f%%, %@), thermal %@%@",
            loadAverage1, activeProcessorCount, normalized * 100, state.rawValue,
            thermalState, isLowPowerMode ? ", low power" : ""
        )
    }
}

/// A fixed unit of CPU work, timed, so a budget can be scaled to the machine it ran on.
///
/// Load average says how many things want to run. It does not say how fast *this* core is
/// today: an M-series laptop on battery, a thermally throttled runner, and a GitHub `macos-26`
/// VM differ by more than 2× with a load average of zero on all three. Timing a kernel whose
/// instruction count is fixed measures that directly, and the ratio against a recorded reference
/// is the honest multiplier for every other budget in the run.
///
/// The kernel mixes arithmetic with random access into a 64 KB array — L2-resident, so it feels
/// memory-system contention from a parallel build without becoming a pure memory benchmark.
public enum MachineCalibration {
    /// Seconds this kernel took on the machine the committed baseline was recorded on.
    ///
    /// **Per configuration, because the two differ by 46×.** Measured as the minimum of thirty
    /// min-of-three runs on the Wave 1 development machine (Apple silicon, 12 cores): 1.47 ms
    /// optimised, 67.8 ms unoptimised. Set a little below each so the factor lands at ~1 here and
    /// above 1 on anything slower — the floor in ``scalingFactor(reference:)`` makes the
    /// too-low direction the safe one.
    ///
    /// A single constant would double-count: `PerfGuard` already applies its own debug
    /// multiplier, so a debug run measured against a release reference would be widened twice.
    ///
    /// This constant is only the in-test flake guard. The authoritative normalisation is done by
    /// `Scripts/bench.sh`, which compares the `machine.calibration.seconds` sample in
    /// `latest.json` against the one in `baseline.json` — see `docs/perf/README.md`.
    #if DEBUG
        public static let referenceSeconds = 0.065
    #else
        public static let referenceSeconds = 0.0014
    #endif

    /// How much slower this machine is than the reference. `1.0` means identical, `2.0` means
    /// half the speed and every wall-clock budget should be doubled.
    ///
    /// Never below `1.0` by ``scalingFactor``: a faster machine must **not** tighten a budget,
    /// or the fastest developer's laptop silently becomes the gate everyone else fails.
    public static func measure(iterations: Int = 3) -> Double {
        var best = Double.greatestFiniteMagnitude
        let clock = ContinuousClock()
        for _ in 0 ..< max(iterations, 1) {
            let elapsed = clock.measure { blackHole(kernel()) }
            best = min(best, seconds(elapsed))
        }
        return best
    }

    /// ``measure(iterations:)`` divided by the reference, floored at 1.
    public static func scalingFactor(reference: Double = referenceSeconds) -> Double {
        guard reference > 0 else { return 1 }
        return max(1, measure() / reference)
    }

    /// The reference kernel. Fixed instruction count, no allocation, no syscalls.
    private static func kernel() -> UInt64 {
        let size = 8192 // 64 KB of UInt64
        var table = [UInt64](repeating: 0, count: size)
        for index in 0 ..< size { table[index] = UInt64(index) &* 0x9E37_79B9_7F4A_7C15 }
        var accumulator: UInt64 = 0x1234_5678
        var cursor = 0
        for _ in 0 ..< 400_000 {
            accumulator = accumulator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            cursor = Int((accumulator >> 33) % UInt64(size))
            accumulator ^= table[cursor]
            table[cursor] = accumulator
        }
        return accumulator
    }

    /// Keeps a value from being optimised away without costing a measurable amount.
    @inline(never)
    public static func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }

    /// A `Duration` as a `Double` of seconds.
    public static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
