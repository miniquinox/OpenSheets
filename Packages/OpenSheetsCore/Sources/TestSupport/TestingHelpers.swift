//
//  TestingHelpers.swift
//  TestSupport
//
//  The thin layer that turns a comparison into a Swift Testing failure with a readable message.
//

import Foundation
import SheetModel
import Testing

// MARK: - Workbook matching

/// Asserts that `workbook` matches its sidecar, and prints the diff when it does not.
///
/// **The brief's `#expect(workbook, matches: expectedJSON)` is not expressible.** `#expect` is a
/// macro over a single boolean expression; there is no overload point for a `matches:` label.
/// The two spellings that do work are this function, and the plain macro with the report passed
/// as its comment:
///
/// ```swift
/// expectMatch(workbook, expected)                      // one line, records the diff
///
/// let result = WorkbookMatcher.compare(workbook, to: expected)
/// #expect(result.matches, "\(result.report())")        // when you want the result too
/// ```
///
/// Returns whether it matched, so a caller can bail out rather than cascade.
@discardableResult
public func expectMatch(
    _ workbook: Workbook,
    _ expected: ExpectedWorkbook,
    options: MatchOptions = .default,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    let result = WorkbookMatcher.compare(workbook, to: expected, options: options)
    return report(
        result,
        subject: expected.file,
        why: expected.proves,
        limit: options.maximumReportedMismatches,
        sourceLocation: sourceLocation
    )
}

/// Asserts that a workbook survived a round trip unchanged.
///
/// PLAN.md §5.2's contract, in one call: read → write → read must be a fixed point. The failure
/// message names the first cell that moved.
@discardableResult
public func expectRoundTrip(
    _ original: Workbook,
    _ reloaded: Workbook,
    options: MatchOptions = .default,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    let result = WorkbookMatcher.compare(original, reloaded, options: options)
    return report(
        result,
        subject: "round trip",
        why: "a read → write → read cycle must be a fixed point (PLAN.md §5.2)",
        limit: options.maximumReportedMismatches,
        sourceLocation: sourceLocation
    )
}

/// Asserts that two sheets agree.
@discardableResult
public func expectSheetsMatch(
    _ lhs: Sheet,
    _ rhs: Sheet,
    styles: StyleTable = .empty,
    options: MatchOptions = .default,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Bool {
    let result = WorkbookMatcher.compare(lhs, rhs, styles: styles, options: options)
    return report(
        result, subject: lhs.name, why: "", limit: options.maximumReportedMismatches,
        sourceLocation: sourceLocation
    )
}

private func report(
    _ result: MatchResult,
    subject: String,
    why: String,
    limit: Int,
    sourceLocation: SourceLocation
) -> Bool {
    guard !result.matches else { return true }
    var message = "\(subject) did not match.\n\(result.report(limit: limit))"
    if !why.isEmpty { message += "\n  this fixture exists to prove: \(why)" }
    Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation)
    return false
}

// MARK: - Errors

/// Asserts that `body` throws a ``SheetError`` whose ``SheetError/code`` is `code`.
///
/// Better than `#expect(throws:)` for this codebase, because `SheetError`'s cases carry payloads
/// that a test does not want to spell out — `zip.bomb.ratio` is the contract, the exact measured
/// ratio in the payload is not.
public func expectThrows(
    code: String,
    orAnyOf alternatives: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> some Any
) {
    let accepted = [code] + alternatives
    do {
        _ = try body()
        Issue.record(
            Comment(rawValue: "expected \(accepted.joined(separator: " or ")), but nothing was thrown"),
            sourceLocation: sourceLocation
        )
    } catch let error as SheetError {
        if !accepted.contains(error.code) {
            Issue.record(
                Comment(rawValue: """
                expected \(accepted.joined(separator: " or ")), got \(error.code)
                  \(error)
                """),
                sourceLocation: sourceLocation
            )
        }
    } catch {
        Issue.record(
            Comment(rawValue: "expected a SheetError \(accepted.joined(separator: " or ")), got \(error)"),
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Performance

extension PerfGuard {
    /// Times `body` and fails only when the machine was quiet enough for the number to mean
    /// something.
    ///
    /// On a loaded machine — which, per the Wave 1 addendum, is the normal state of this Mac —
    /// the measurement is still taken, still recorded, and still compared against the committed
    /// baseline by `Scripts/bench.sh`. What is waived is the in-test assertion, and it is waived
    /// *loudly*: the warning names the load, so a run that skipped its gate cannot be mistaken
    /// for a run that passed one.
    ///
    /// Returns the timing so a caller can assert something else about it.
    @discardableResult
    public static func expect(
        _ id: String,
        budget: Duration,
        iterations: Int = 5,
        warmups: Int = 1,
        sourceLocation: SourceLocation = #_sourceLocation,
        body: () throws -> Void
    ) rethrows -> Timing {
        let timing = try measure(id: id, budget: budget, iterations: iterations, warmups: warmups, body: body)
        print("  \(timing.summary)")
        guard !timing.passed else { return timing }

        if timing.status == .degraded {
            // Deliberately a warning and not an Issue. See the doc comment.
            Issue.record(
                Comment(rawValue: """
                ⚠︎ PERF GATE WAIVED — \(id) missed its budget while the machine was loaded, so the \
                result is not trustworthy either way.
                  \(timing.summary)
                  \(timing.load.summary)
                  Re-run on an idle machine before believing this, and compare docs/perf/latest.json \
                  against docs/perf/baseline.json — that comparison is load-aware and is the real gate.
                """),
                sourceLocation: sourceLocation
            )
            return timing
        }

        Issue.record(
            Comment(rawValue: """
            \(id) exceeded its budget.
              \(timing.summary)
              \(timing.load.summary)
              budget as written \(timing.budget.map { String(format: "%.4fs", $0) } ?? "none"), \
            scaled by \(configuration == "debug" ? "6× debug × " : "")\
            \(String(format: "%.2f×", timing.machineFactor)) machine speed
            """),
            sourceLocation: sourceLocation
        )
        return timing
    }

    /// Asserts a work-done number against a ceiling, which is safe to do on any machine.
    ///
    /// This is the assertion to reach for. A count of allocations, syscalls, visited nodes or
    /// resident bytes does not change because another agent started a build.
    @discardableResult
    public static func expectWork(
        _ id: String,
        value: Double,
        atMost ceiling: Double,
        unit: BenchmarkUnit,
        note: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        let sample = record(id: id, value: value, unit: unit, budget: ceiling, note: note)
        let passed = sample.withinBudget ?? true
        if !passed {
            Issue.record(
                Comment(rawValue: """
                \(id): \(describe(value, unit)) exceeds the ceiling of \(describe(ceiling, unit))\
                \(note.map { " — \($0)" } ?? "")
                """),
                sourceLocation: sourceLocation
            )
        }
        return passed
    }

    private static func describe(_ value: Double, _ unit: BenchmarkUnit) -> String {
        switch unit {
        case .bytes: ByteCount.describe(Int(value))
        case .seconds: String(format: "%.4f s", value)
        case .milliseconds: String(format: "%.2f ms", value)
        case .ratio: String(format: "%.1f%%", value * 100)
        case .rate: String(format: "%.0f/s", value)
        case .count: String(Int(value))
        }
    }
}
