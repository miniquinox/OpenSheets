//
//  PerfHarness.swift
//  TestSupport
//
//  The measurement side of the performance gate: one JSON line per metric, robust under load.
//

import Foundation
import Synchronization

/// What a benchmark number is counted in.
public enum BenchmarkUnit: String, Sendable, Hashable, Codable, CaseIterable {
    case seconds
    case milliseconds
    case bytes
    /// A plain count — allocations, syscalls, visited nodes, cells.
    case count
    /// A ratio in `0` to `1`, such as a cache hit rate.
    case ratio
    /// Items per second.
    case rate

    /// Whether a smaller number is better. Only ``ratio`` and ``rate`` want to go up.
    public var lowerIsBetter: Bool {
        switch self {
        case .seconds, .milliseconds, .bytes, .count: true
        case .ratio, .rate: false
        }
    }
}

/// How a measurement went.
public enum BenchmarkStatus: String, Sendable, Hashable, Codable, CaseIterable {
    /// Taken on a machine quiet enough for the number to mean something.
    case measured
    /// Taken, but the machine was loaded. The value is recorded and comparable, but a timing
    /// assertion against it was widened or waived.
    case degraded
    /// Not taken. The metric still appears in the output so a missing number is visible rather
    /// than silently absent.
    case skipped
    /// Not measurable yet because the code it measures does not exist.
    case blocked
}

/// One recorded number.
public struct BenchmarkSample: Sendable, Hashable, Codable {
    /// Dotted and stable — `xlsx.read.100k.seconds`. **Never rename one**: the baseline is keyed
    /// on it, and a rename silently drops the metric from the comparison rather than failing.
    public var id: String
    public var value: Double
    public var unit: BenchmarkUnit
    /// The budget from PLAN.md §10.6, if this metric has one.
    public var budget: Double?
    public var status: BenchmarkStatus
    /// How many timed runs the value is the minimum of.
    public var samples: Int
    /// The machine's speed relative to the baseline machine, as measured by
    /// ``MachineCalibration``. `1.0` on the reference.
    public var machineFactor: Double?
    /// One-minute load average per core at the time of measurement.
    public var normalizedLoad: Double?
    public var note: String?

    public init(
        id: String,
        value: Double,
        unit: BenchmarkUnit,
        budget: Double? = nil,
        status: BenchmarkStatus = .measured,
        samples: Int = 1,
        machineFactor: Double? = nil,
        normalizedLoad: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.value = value
        self.unit = unit
        self.budget = budget
        self.status = status
        self.samples = samples
        self.machineFactor = machineFactor
        self.normalizedLoad = normalizedLoad
        self.note = note
    }

    /// Whether the value is inside its budget, ignoring machine speed.
    public var withinBudget: Bool? {
        guard let budget else { return nil }
        return unit.lowerIsBetter ? value <= budget : value >= budget
    }
}

/// Collects benchmark samples and emits them where `Scripts/bench.sh` can find them.
///
/// The transport is deliberately the dumbest thing that works: one line of JSON per sample on
/// standard output, prefixed with a sentinel. `swift test` interleaves output from parallel
/// suites, buffers unpredictably, and formats failures differently between versions — but a
/// grep for a sentinel at the start of a line survives all of that, needs no new SwiftPM target
/// (which would mean editing a `Package.swift` that A0 owns), and works identically from every
/// test target.
///
/// **Any agent can emit into the same report.** A1 measuring an xlsx open, A4 measuring a scroll
/// frame, A3 measuring a recalc: call ``record(id:value:unit:budget:note:)`` and the number lands
/// in `docs/perf/latest.json` alongside everything else. That is the whole point of putting this
/// in `TestSupport` rather than in one agent's test target.
public enum Benchmark {
    /// The sentinel `Scripts/bench.sh` greps for.
    public static let marker = "@@OPENSHEETS_BENCH@@"

    /// The environment variable that turns the heavy benchmark lane on.
    public static let environmentKey = "OPENSHEETS_BENCH"

    private static let collected = Mutex<[BenchmarkSample]>([])

    /// Whether the benchmark lane is enabled.
    ///
    /// Gate a heavy suite on this — `@Suite(.enabled(if: Benchmark.isEnabled))` — so a normal
    /// `swift test` stays fast for the other six agents and `Scripts/bench.sh` gets the numbers.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Every sample recorded in this process, in order.
    public static var recorded: [BenchmarkSample] { collected.withLock { $0 } }

    /// Records a sample and prints it for the harness.
    public static func record(_ sample: BenchmarkSample) {
        collected.withLock { $0.append(sample) }
        emit(sample)
    }

    /// Records a sample from its parts.
    public static func record(
        id: String,
        value: Double,
        unit: BenchmarkUnit,
        budget: Double? = nil,
        status: BenchmarkStatus = .measured,
        samples: Int = 1,
        note: String? = nil
    ) {
        let load = MachineLoad.sample()
        record(BenchmarkSample(
            id: id,
            value: value,
            unit: unit,
            budget: budget,
            status: status,
            samples: samples,
            normalizedLoad: load.normalized,
            note: note
        ))
    }

    /// Records a metric that cannot be measured in this build, so the report says so out loud.
    ///
    /// A budget that quietly vanishes from the JSON is a budget nobody is watching. This keeps
    /// it visible, with the reason attached.
    public static func blocked(id: String, unit: BenchmarkUnit, budget: Double?, blockedOn: String) {
        record(BenchmarkSample(
            id: id, value: .nan, unit: unit, budget: budget, status: .blocked, samples: 0,
            note: "blocked on \(blockedOn)"
        ))
    }

    /// Forgets everything recorded so far. For the harness's own tests.
    public static func reset() {
        collected.withLock { $0.removeAll() }
    }

    /// Prints one sample as `@@OPENSHEETS_BENCH@@ {…}`.
    public static func emit(_ sample: BenchmarkSample) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sample) else { return }
        print("\(marker) \(String(decoding: data, as: UTF8.self))")
        // Test runners buffer aggressively and a crash mid-suite would otherwise lose every
        // number taken before it. Flushing costs nothing at this cadence.
        fflush(stdout)
    }
}

/// Times work in a way that survives a busy machine.
///
/// Four decisions, all aimed at Wave 1 addendum §8:
///
/// 1. **Warm-up runs are discarded.** The first pass pays for page faults, lazy globals and an
///    unwarmed branch predictor, and none of that is what the budget is about.
/// 2. **The reported value is the minimum, not the mean.** Contention can only ever make a run
///    slower, so the fastest of N is the best available estimate of the uncontended cost. A mean
///    is a measurement of how busy the machine was.
/// 3. **The budget is scaled**, by the debug penalty and by ``MachineCalibration``'s measured
///    machine speed, so the same budget can be written once and checked everywhere.
/// 4. **An overloaded machine downgrades rather than fails.** The number is still recorded and
///    still compared against the baseline by `Scripts/bench.sh`; only the in-test assertion is
///    waived, with a note saying why.
public enum PerfGuard {
    /// The penalty an unoptimised build pays, matching `SheetModelTests.BenchmarkTests`.
    ///
    /// Six, not "some": bounds checking, retain/release traffic and no inlining together cost
    /// about that on this codebase. Stated rather than hidden so nobody reads a green debug run
    /// as proof the release budget holds.
    #if DEBUG
        public static let debugSlack = 6.0
        public static let configuration = "debug"
    #else
        public static let debugSlack = 1.0
        public static let configuration = "release"
    #endif

    /// What one timed measurement produced.
    public struct Timing: Sendable, Hashable {
        public var id: String
        /// The fastest run, in seconds. This is the reported value.
        public var best: Double
        /// The slowest run, in seconds — the spread against ``best`` says how noisy the machine
        /// was, which is worth printing when a run is surprising.
        public var worst: Double
        public var samples: Int
        public var load: MachineLoad
        public var machineFactor: Double
        /// The budget as written, before scaling.
        public var budget: Double?
        /// The budget after the debug and machine multipliers.
        public var effectiveBudget: Double?
        public var status: BenchmarkStatus

        /// Whether the fastest run met the scaled budget.
        public var passed: Bool {
            guard let effectiveBudget else { return true }
            return best <= effectiveBudget
        }

        /// How much of the scaled budget was used.
        public var budgetUsed: Double? {
            guard let effectiveBudget, effectiveBudget > 0 else { return nil }
            return best / effectiveBudget
        }

        public var summary: String {
            var text = String(format: "[perf/%@] %@: %.4fs", PerfGuard.configuration, id, best)
            if let effectiveBudget {
                text += String(format: " (budget %.4fs, %.0f%% used)", effectiveBudget, (budgetUsed ?? 0) * 100)
            }
            text += String(format: ", spread %.0f%%", worst > 0 ? (worst - best) / worst * 100 : 0)
            if status == .degraded { text += " — DEGRADED: \(load.summary)" }
            return text
        }
    }

    /// Runs `body` `iterations` times after `warmups` untimed runs, records the fastest, and
    /// hands back what happened.
    ///
    /// Nothing here asserts. The caller decides — see `PerfGuard.expect(_:)` in
    /// `TestingHelpers.swift` for the assertion wrapper that knows about `Issue`.
    @discardableResult
    public static func measure(
        id: String,
        budget: Duration? = nil,
        iterations: Int = 5,
        warmups: Int = 1,
        machineFactor: Double? = nil,
        body: () throws -> Void
    ) rethrows -> Timing {
        let load = MachineLoad.sample()
        let factor = machineFactor ?? MachineCalibration.scalingFactor()
        let clock = ContinuousClock()

        for _ in 0 ..< max(warmups, 0) {
            try body()
        }

        var best = Double.greatestFiniteMagnitude
        var worst = 0.0
        let runs = max(iterations, 1)
        for _ in 0 ..< runs {
            let elapsed = try clock.measure { try body() }
            let seconds = MachineCalibration.seconds(elapsed)
            best = min(best, seconds)
            worst = max(worst, seconds)
        }

        let budgetSeconds = budget.map(MachineCalibration.seconds)
        let effective = budgetSeconds.map { $0 * debugSlack * factor * load.recommendedSlack }
        let status: BenchmarkStatus = load.permitsTimingAssertions ? .measured : .degraded

        let timing = Timing(
            id: id,
            best: best,
            worst: worst,
            samples: runs,
            load: load,
            machineFactor: factor,
            budget: budgetSeconds,
            effectiveBudget: effective,
            status: status
        )

        Benchmark.record(BenchmarkSample(
            id: id,
            value: best,
            unit: .seconds,
            budget: budgetSeconds,
            status: status,
            samples: runs,
            machineFactor: factor,
            normalizedLoad: load.normalized,
            note: status == .degraded ? "machine loaded: \(load.summary)" : nil
        ))
        return timing
    }

    /// Records a work-done number — allocations, syscalls, visited nodes, bytes.
    ///
    /// Prefer this to ``measure(id:budget:iterations:warmups:machineFactor:body:)`` wherever the
    /// question can be asked as a count. A count is identical on an idle machine and a hammered
    /// one, which is the only kind of assertion that can be trusted in this repository right now.
    @discardableResult
    public static func record(
        id: String,
        value: Double,
        unit: BenchmarkUnit,
        budget: Double? = nil,
        note: String? = nil
    ) -> BenchmarkSample {
        let load = MachineLoad.sample()
        let sample = BenchmarkSample(
            id: id,
            value: value,
            unit: unit,
            budget: budget,
            status: .measured,
            samples: 1,
            normalizedLoad: load.normalized,
            note: note
        )
        Benchmark.record(sample)
        return sample
    }
}
