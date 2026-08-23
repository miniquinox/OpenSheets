import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("WorkbookMatcher")
struct WorkbookMatcherTests {
    private func sidecar(
        cells: [String: ExpectedCell],
        sheetName: String = "Data",
        usedRange: String? = nil,
        merges: [String]? = nil,
        skipChecks: [String]? = nil
    ) -> ExpectedWorkbook {
        ExpectedWorkbook(
            file: "synthetic/inline.xlsx",
            kind: .xlsx,
            proves: "the matcher works",
            valuesVerifiedBy: "hand-written in this test",
            dateSystem: 1900,
            sheets: [ExpectedSheet(
                name: sheetName,
                index: 0,
                visibility: "visible",
                usedRange: usedRange,
                cells: cells,
                merges: merges
            )],
            skipChecks: skipChecks
        )
    }

    @Test("a workbook that matches its sidecar reports no mismatches and a non-zero check count")
    func happyPath() throws {
        let workbook = try WorkbookBuilder().sheet("Data").cell("A1", 42).cell("B1", "hi").build()
        let result = WorkbookMatcher.compare(workbook, to: sidecar(cells: [
            "A1": ExpectedCell(type: "number", value: .number(42)),
            "B1": ExpectedCell(type: "text", value: .string("hi")),
        ]))

        #expect(result.matches, "\(result.report())")
        #expect(result.checked > 0, "a green result with zero checks is a broken test, not a pass")
    }

    @Test("the failure names the cell, the expected value, the actual value and the delta")
    func usefulDiff() throws {
        let workbook = try WorkbookBuilder().sheet("Data").cell("D7", 42.000_000_1).build()
        let options = MatchOptions(absoluteTolerance: 1e-9)
        let result = WorkbookMatcher.compare(
            workbook,
            to: sidecar(cells: ["D7": ExpectedCell(type: "number", value: .number(42))]),
            options: options
        )

        #expect(!result.matches)
        let message = try #require(result.mismatches.first).description
        // "cell D7: expected 42, got 42.0000001" beats "not equal".
        #expect(message.contains("Data!D7"))
        #expect(message.contains("expected 42,"))
        #expect(message.contains("42.0000001"))
        #expect(message.contains("Δ"))
        #expect(message.contains("tolerance"))
    }

    @Test("42 does not print as 42.0")
    func integralNumbersReadAsIntegers() {
        #expect(WorkbookMatcher.format(number: 42) == "42")
        #expect(WorkbookMatcher.format(number: -7) == "-7")
        #expect(WorkbookMatcher.format(number: 0.5) == "0.5")
        #expect(WorkbookMatcher.format(number: .nan) == "NaN")
    }

    @Test("the tolerance forgives the last ulp and nothing more")
    func tolerance() {
        let loose = MatchOptions(absoluteTolerance: 1e-9)
        #expect(WorkbookMatcher.valuesMatch(.number(0.1), .number(0.1 + 1e-12), options: loose))
        #expect(!WorkbookMatcher.valuesMatch(.number(0.1), .number(0.100_001), options: loose))

        let exact = MatchOptions.strict
        #expect(!WorkbookMatcher.valuesMatch(.number(0.1), .number(0.1 + 1e-12), options: exact))
        #expect(WorkbookMatcher.valuesMatch(.number(0.1), .number(0.1), options: exact))
    }

    @Test("the 1462-day epoch shift is called out by name")
    func epochShiftHint() throws {
        let workbook = try WorkbookBuilder().sheet("Data").cell("A1", 45_000).build()
        let result = WorkbookMatcher.compare(
            workbook,
            to: sidecar(cells: ["A1": ExpectedCell(type: "number", value: .number(45_000 - 1462))])
        )
        let detail = try #require(result.mismatches.first?.detail)
        #expect(detail.contains("1462"))
        #expect(detail.contains("1904"))
    }

    @Test("a sidecar value of null asserts existence, not content")
    func existenceOnly() throws {
        let volatileCell = ExpectedCell(type: "number", value: nil, formula: "TODAY()")
        let present = try WorkbookBuilder()
            .sheet("Data").formula("A1", "TODAY()", cached: .number(45_000)).build()
        #expect(WorkbookMatcher.compare(present, to: sidecar(cells: ["A1": volatileCell])).matches)

        let absent = try WorkbookBuilder().sheet("Data").formula("A1", "TODAY()").build()
        let result = WorkbookMatcher.compare(absent, to: sidecar(cells: ["A1": volatileCell]))
        #expect(!result.matches)
        #expect(result.mismatches.first?.kind == .missing)
    }

    @Test("skipChecks exempts an assertion and says so rather than passing silently")
    func skipChecks() throws {
        let workbook = try WorkbookBuilder().sheet("Volatile").cell("B1", 1).build()
        let expected = sidecar(
            cells: ["B1": ExpectedCell(type: "number", value: .number(999))],
            sheetName: "Volatile",
            skipChecks: ["cellValue:Volatile!B1"]
        )
        let result = WorkbookMatcher.compare(workbook, to: expected)
        #expect(result.matches)
        #expect(result.skipped.contains("cellValue:Volatile!B1"))
        #expect(result.report().contains("skipped"))
    }

    @Test("usedRange is compared merge-aware, as the corpus records it")
    func usedRangeIsMergeAware() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Data").cell("A1", "title").merge("A1:D1").build()

        #expect(WorkbookMatcher.compare(
            workbook,
            to: sidecar(cells: [:], usedRange: "A1:D1", merges: ["A1:D1"])
        ).matches)

        let wrong = WorkbookMatcher.compare(
            workbook,
            to: sidecar(cells: [:], usedRange: "A1:A1", merges: ["A1:D1"])
        )
        #expect(!wrong.matches)
        #expect(try #require(wrong.mismatches.first).detail?.contains("merge") == true)
    }

    @Test("a missing sheet is reported once, not once per cell")
    func missingSheet() throws {
        let workbook = try WorkbookBuilder().sheet("Elsewhere").cell("A1", 1).build()
        let result = WorkbookMatcher.compare(workbook, to: sidecar(cells: [
            "A1": ExpectedCell(type: "number", value: .number(1)),
            "A2": ExpectedCell(type: "number", value: .number(2)),
        ]))
        #expect(result.mismatches.count { $0.kind == .missing } == 1)
    }

    @Test("a dropped sheet fragment is reported as the file-damaging change it is")
    func fragmentLoss() throws {
        let withFragment = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1).fragment("drawing", xml: "<drawing r:id=\"rId1\"/>").build()
        let without = try WorkbookBuilder().sheet("Data").cell("A1", 1).build()

        let result = WorkbookMatcher.compare(withFragment, without)
        #expect(!result.matches)
        let mismatch = try #require(result.mismatches.first { $0.path.contains("sheetLevelFragments") })
        #expect(mismatch.detail?.contains("damaged") == true)
    }

    @Test("a fragment whose bytes changed is reported even when the element list matches")
    func fragmentBytesChanged() throws {
        let original = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1).fragment("pageMargins", xml: "<pageMargins left=\"0.7\"/>").build()
        let normalized = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1).fragment("pageMargins", xml: "<pageMargins left='0.7'/>").build()

        let result = WorkbookMatcher.compare(original, normalized)
        #expect(!result.matches)
        #expect(result.mismatches.contains { $0.detail?.contains("byte-for-byte") == true })
    }

    @Test("a passthrough part that was re-encoded rather than copied is caught")
    func passthroughRewritten() throws {
        let original = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1)
            .passthroughPart(path: "xl/charts/chart1.xml", contents: Data("<chart/>".utf8))
            .build()
        let rewritten = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1)
            .passthroughPart(path: "xl/charts/chart1.xml", contents: Data("<chart />".utf8))
            .build()

        let result = WorkbookMatcher.compare(original, rewritten)
        #expect(!result.matches)
        #expect(result.mismatches.contains { $0.path.contains("chart1.xml") })
    }

    @Test("a dropped passthrough part names what was lost")
    func passthroughDropped() throws {
        let original = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1)
            .passthroughPart(path: "xl/vbaProject.bin", contents: Data([0x01, 0x02]))
            .build()
        let stripped = try WorkbookBuilder().sheet("Data").cell("A1", 1).build()

        let result = WorkbookMatcher.compare(original, stripped)
        #expect(result.mismatches.contains { $0.detail?.contains("xl/vbaProject.bin") == true })
    }

    @Test("style comparison mode decides whether a renumbered index is a failure")
    func styleComparisonModes() throws {
        var byIndex = StyleTable()
        _ = byIndex.intern(CellStyle(numberFormatID: 44))

        let left = try WorkbookBuilder()
            .sheet("Data").cell("A1", 1).style("A1", CellStyle(numberFormatID: 44)).build()
        // Same appearance, different index: an extra style interned first pushes it along.
        let right = try WorkbookBuilder()
            .sheet("Data")
            .cell("A1", 1)
            .columnStyle(CellStyle(numberFormatID: 9), columns: 20 ... 20)
            .style("A1", CellStyle(numberFormatID: 44))
            .build()

        #expect(!WorkbookMatcher.compare(left, right, options: .strict).matches)
        var resolved = MatchOptions.default
        resolved.styleComparison = .resolved
        let byAppearance = WorkbookMatcher.compare(left, right, options: resolved)
        #expect(byAppearance.mismatches.allSatisfy { $0.kind != .style }, "\(byAppearance.report())")
    }

    @Test("the report truncates rather than printing ten thousand lines")
    func reportTruncates() throws {
        var cells: [String: ExpectedCell] = [:]
        for row in 1 ... 60 {
            cells["A\(row)"] = ExpectedCell(type: "number", value: .number(Double(row)))
        }
        let empty = try WorkbookBuilder().sheet("Data").cell("Z1", 0).build()
        let result = WorkbookMatcher.compare(empty, to: sidecar(cells: cells))
        let report = result.report(limit: 5)
        #expect(report.contains("and 5"))
        #expect(report.split(separator: "\n").count < 12)
    }

    @Test("the date system is checked, because getting it wrong shifts every date")
    func dateSystemChecked() throws {
        let workbook = try WorkbookBuilder().sheet("Data").cell("A1", 1).dateSystem(.excel1904).build()
        var expected = sidecar(cells: [:])
        expected.dateSystem = 1900
        let result = WorkbookMatcher.compare(workbook, to: expected)
        #expect(result.mismatches.contains { $0.path == "workbook.dateSystem" })
    }
}
