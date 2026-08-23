import Foundation
import SheetModel
import Testing
@testable import TestSupport

/// The helpers that turn a comparison into a failure are themselves assertions, so testing them
/// means asserting that they *fail* when they should. `withKnownIssue` is how: it expects an issue
/// inside its body and fails if none arrives.
@Suite("Testing helpers")
struct TestingHelpersTests {
    private func sidecar(_ cells: [String: ExpectedCell]) -> ExpectedWorkbook {
        ExpectedWorkbook(
            file: "synthetic/helpers.xlsx",
            kind: .xlsx,
            proves: "the helper reports what it should",
            sheets: [ExpectedSheet(name: "Data", index: 0, cells: cells)]
        )
    }

    @Test("expectMatch is silent on a match and records a diff on a mismatch")
    func expectMatchBehaviour() throws {
        let workbook = try WorkbookBuilder().sheet("Data").cell("A1", 42).build()

        #expect(expectMatch(workbook, sidecar(["A1": ExpectedCell(type: "number", value: .number(42))])))

        withKnownIssue("the point of the test is that this records one") {
            let matched = expectMatch(workbook, sidecar(["A1": ExpectedCell(type: "number", value: .number(7))]))
            #expect(!matched)
        }
    }

    @Test("expectRoundTrip records the first cell that moved")
    func expectRoundTripBehaviour() throws {
        let original = try WorkbookBuilder().sheet("Data").cell("A1", 1).cell("B1", 2).build()
        #expect(expectRoundTrip(original, original))

        let mangled = try WorkbookBuilder().sheet("Data").cell("A1", 1).cell("B1", 99).build()
        withKnownIssue {
            #expect(!expectRoundTrip(original, mangled))
        }
    }

    @Test("expectSheetsMatch compares two sheets directly")
    func expectSheetsMatchBehaviour() throws {
        let left = try WorkbookBuilder().sheet("Data").cell("A1", 1).buildSheet()
        #expect(expectSheetsMatch(left, left))

        let right = try WorkbookBuilder().sheet("Data").cell("A1", 2).buildSheet()
        withKnownIssue {
            #expect(!expectSheetsMatch(left, right))
        }
    }

    @Test("expectThrows accepts the code it was given")
    func expectThrowsMatchingCode() {
        expectThrows(code: "file.diskFull") {
            throw SheetError.diskFull(path: "/tmp")
        }
    }

    @Test("expectThrows accepts an alternative code")
    func expectThrowsAlternative() {
        expectThrows(code: "zip.bomb.ratio", orAnyOf: ["zip.bomb.entry"]) {
            throw SheetError.archiveEntryTooLarge(path: "x", declaredBytes: 1, limit: 0)
        }
    }

    @Test("expectThrows fails when nothing is thrown")
    func expectThrowsSilence() {
        withKnownIssue {
            expectThrows(code: "file.diskFull") { 42 }
        }
    }

    @Test("expectThrows fails on the wrong code, and names both")
    func expectThrowsWrongCode() {
        withKnownIssue {
            expectThrows(code: "file.diskFull") {
                throw SheetError.fileNotFound(path: "/tmp/missing")
            }
        }
    }

    @Test("expectThrows fails on an error that is not a SheetError")
    func expectThrowsForeignError() {
        struct Foreign: Error {}
        withKnownIssue {
            expectThrows(code: "file.diskFull") { throw Foreign() }
        }
    }

    @Test("expectWork passes under its ceiling and fails over it")
    func expectWorkBehaviour() {
        Benchmark.reset()
        #expect(PerfGuard.expectWork("test.helpers.under", value: 5, atMost: 10, unit: .count))
        withKnownIssue {
            #expect(!PerfGuard.expectWork("test.helpers.over", value: 50, atMost: 10, unit: .count))
        }
        #expect(Benchmark.recorded.count == 2, "both attempts are recorded, pass or fail")
        Benchmark.reset()
    }

    /// Only meaningful when the machine is quiet enough for the gate to be live: on a loaded
    /// machine `PerfGuard.expect` downgrades to a warning by design. `.enabled(if:)` rather than
    /// a `#require` inside, because a machine that is busy should make this test *not run*, not
    /// make it fail.
    @Test(
        "a perf assertion that misses its budget on a quiet machine records an issue",
        .enabled(if: MachineLoad.sample().permitsTimingAssertions)
    )
    func perfExpectRecordsOnMiss() {
        Benchmark.reset()
        withKnownIssue {
            PerfGuard.expect("test.helpers.slow", budget: .nanoseconds(1), iterations: 1, warmups: 0) {
                var accumulator: UInt64 = 0
                for index in 0 ..< 2_000_000 { accumulator = accumulator &+ UInt64(index) }
                MachineCalibration.blackHole(accumulator)
            }
        }
        Benchmark.reset()
    }
}
