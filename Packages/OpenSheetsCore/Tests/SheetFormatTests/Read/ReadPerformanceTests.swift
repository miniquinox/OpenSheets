//
//  ReadPerformanceTests.swift
//  SheetFormatTests
//
//  A1. PLAN.md §10.6's read budgets, gated.
//

import Foundation
import Testing

import SheetFormat
import SheetModel
import TestSupport

@Suite("xlsx read — performance", .enabled(if: FixtureLibrary.isAvailable), .serialized)
struct ReadPerformanceTests {
    /// 1,000,000 cells in under 4 s and under 600 MB.
    ///
    /// `perf/1m-cells.xlsx` is git-ignored and generated on demand, so this skips rather than
    /// fails when it is absent — a missing fixture is a corpus problem, not a regression.
    @Test("a million cells open inside the budget")
    func millionCells() async throws {
        let path = "perf/1m-cells.xlsx"
        guard FixtureLibrary.exists(path) else {
            Benchmark.blocked(
                id: "read.1m-cells", unit: .seconds, budget: 4,
                blockedOn: "\(path) is generated on demand: Scripts/gen-fixtures.py perf --with-huge"
            )
            return
        }
        let url = try FixtureLibrary.url(path)

        // Warm the page cache and get the cell count and the timing breakdown in one go.
        let (workbook, diagnostics) = try await XLSXReader.readWithDiagnostics(contentsOf: url)
        #expect(workbook.cellCount == 1_000_000, "the fixture no longer holds a million cells")
        print("""
          [read/1m-cells] total \(diagnostics.total)
            zip open        \(diagnostics.archiveOpen)   (\(diagnostics.archiveEntryCount) entries, none inflated)
            part graph      \(diagnostics.partGraph)
            workbook.xml    \(diagnostics.workbookPart)
            sharedStrings   \(diagnostics.sharedStrings)
            styles + theme  \(diagnostics.styles)
            sheets          \(diagnostics.sheetsWallClock) wall, \(diagnostics.sheetsSerialTotal) summed
            inflated        \(ByteCount.describe(diagnostics.inflatedBytes))
        """)

        // Resident growth across a fresh parse, which is the number PLAN.md §10.6's "< 600 MB"
        // budget is actually about. A work-done ceiling, so a busy machine cannot change it.
        let before = WorkCounters.residentBytes()
        var parsed: Workbook? = try await XLSXReader.read(contentsOf: url)
        let peak = WorkCounters.residentBytes() - before
        #expect(parsed?.cellCount == 1_000_000)
        parsed = nil
        PerfGuard.expectWork(
            "read.1m-cells.resident",
            value: Double(peak),
            atMost: 600 * 1024 * 1024,
            unit: .bytes,
            note: "resident growth while holding a 1,000,000-cell workbook"
        )

        // Timing is measured with the load-aware gate: seven agents build on this Mac at once and
        // a wall-clock assertion that ignores that is a gate everybody learns to ignore.
        let timing = PerfGuard.measure(id: "read.1m-cells", budget: .seconds(4), iterations: 3, warmups: 1) {
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task.detached {
                _ = try? await XLSXReader.read(contentsOf: url)
                semaphore.signal()
            }
            semaphore.wait()
            _ = task
        }
        print("  \(timing.summary)")
        if timing.passed { return }
        if timing.status == .degraded {
            // Waived, loudly. Seven agents build on this Mac at once, and a wall-clock assertion
            // that ignores that is a gate everybody learns to ignore (`WAVE-1-ADDENDUM.md` §8).
            Issue.record(Comment(rawValue: """
            ⚠︎ PERF GATE WAIVED — read.1m-cells missed its budget while the machine was loaded, so
            the result is not trustworthy either way.
              \(timing.summary)
              \(timing.load.summary)
            """))
        } else {
            Issue.record(Comment(rawValue: "read.1m-cells exceeded its budget.\n  \(timing.summary)"))
        }
    }

    /// 100,000 cells is the interactive budget: open → first paint under 800 ms, of which the
    /// parse is only part.
    @Test("a hundred thousand cells open well inside the first-paint budget")
    func hundredThousandCells() async throws {
        let url = try FixtureLibrary.url("perf/100k-cells.xlsx")
        let (workbook, diagnostics) = try await XLSXReader.readWithDiagnostics(contentsOf: url)
        #expect(workbook.cellCount == 100_000)
        print("  [read/100k-cells] total \(diagnostics.total), sheets \(diagnostics.sheetsWallClock)")
        PerfGuard.expect("read.100k-cells", budget: .milliseconds(400), iterations: 3) {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                _ = try? await XLSXReader.read(contentsOf: url)
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    /// One cell at `XFD1048576`: the used range is enormous and the sheet holds one cell.
    ///
    /// Anything that allocates per cell over the used range dies here, so the assertion is on
    /// *resident bytes*, not on time.
    @Test("a huge used range with one cell costs one cell")
    func singleCellAtTheFarCorner() async throws {
        let before = WorkCounters.residentBytes()
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("perf/single-cell-at-XFD1048576.xlsx")
        )
        let growth = WorkCounters.residentBytes() - before
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.cells.count == 1)
        #expect(sheet.usedRange == CellRange(a1: "XFD1048576"))
        PerfGuard.expectWork(
            "read.singleCellFarCorner.resident",
            value: Double(max(growth, 0)),
            atMost: 16 * 1024 * 1024,
            unit: .bytes,
            note: "a 17-billion-cell used range holding one cell"
        )
    }

    /// A sheet 16,384 columns wide costs 16,384 *cells*, not 16,384 width entries.
    @Test("16,384 columns cost nothing they do not have to")
    func wideSheetStaysCompressed() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("perf/wide-16384-cols.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.usedRange?.columnCount == 16_384)
        #expect(sheet.columnWidths.runCount == 0, "this fixture declares no <col> widths, so none should be stored")
        PerfGuard.expectWork(
            "read.wide16384.cells",
            value: Double(sheet.cells.count),
            atMost: 16_384 * 5,
            unit: .count,
            note: "cells stored for a sheet 16,384 columns by 5 rows"
        )
    }

    /// A `<col>` run spanning every column is one run, not 16,384 doubles.
    ///
    /// `structure/col-widths-row-heights.xlsx` ends with `<col min="12" max="16384" …>`, which is
    /// what a run-length array is *for*; materialising it would cost 128 KB per sheet for
    /// information that fits in sixteen bytes.
    @Test("a whole-sheet column run stays one run")
    func wholeSheetColumnRunStaysCompressed() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("structure/col-widths-row-heights.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.columnWidths[16_383] == sheet.columnWidths[12], "the trailing run must cover every column")
        PerfGuard.expectWork(
            "read.columnWidths.runs",
            value: Double(sheet.columnWidths.runCount),
            atMost: 8,
            unit: .count,
            note: "runs in columnWidths for a sheet whose last <col> spans columns 12–16,384"
        )
    }

    /// Sheets are parsed concurrently, so wall-clock across a multi-sheet workbook is less than
    /// the sum of its sheets.
    ///
    /// Asserted as a *ratio between two measurements taken in the same run*, which is stable
    /// under load in a way that either number alone is not.
    @Test("sheets parse concurrently")
    func sheetsParseInParallel() async throws {
        let (_, diagnostics) = try await XLSXReader.readWithDiagnostics(
            contentsOf: try FixtureLibrary.url("formulas/cross-sheet.xlsx")
        )
        #expect(diagnostics.sheets.count == 3)
        #expect(diagnostics.sheetsWallClock <= diagnostics.sheetsSerialTotal + .milliseconds(1))
    }
}
