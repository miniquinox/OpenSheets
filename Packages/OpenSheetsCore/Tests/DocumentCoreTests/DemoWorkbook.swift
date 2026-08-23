import DocumentCore
import Foundation
import SheetFormat
import SheetModel
import TestSupport
import Testing

/// Writes the workbook the screenshots in `docs/design/` are taken of.
///
/// Gated on an environment variable so it never runs in CI, and written through A2's own writer so
/// the file the design review looks at is a file the product can actually produce:
///
/// ```
/// OPENSHEETS_DEMO_DIR=/tmp/demo swift test --filter writesTheDemoWorkbook
/// ```
@Suite struct DemoWorkbook {
    @Test func writesTheDemoWorkbook() throws {
        guard let directory = ProcessInfo.processInfo.environment["OPENSHEETS_DEMO_DIR"] else { return }
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var builder = WorkbookBuilder()
            .sheet("Summary")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .columnWidth(150, columns: 0 ... 0)
            .columnWidth(92, columns: 1 ... 5)
            .rows("A1", [
                [.text("Line item"), .text("Q1"), .text("Q2"), .text("Q3"), .text("Q4"), .text("Q4 +8%")],
            ])
        let lines: [(String, Double)] = [
            ("Salaries", 418_500), ("Contractors", 47_900), ("Cloud hosting", 14_472),
            ("Travel", 20_304), ("Equipment", 33_696), ("Marketing", 112_968),
            ("Recruiting", 12_312), ("Office lease", 29_700), ("Software", 52_164),
            ("Legal", 28_836), ("Insurance", 13_068), ("Training", 17_712),
            ("Misc", 5_697),
        ]
        for (index, line) in lines.enumerated() {
            let row = index + 2
            builder = builder
                .cell("A\(row)", .text(line.0))
                .cell("B\(row)", .number(line.1 * 0.94))
                .cell("C\(row)", .number(line.1 * 0.97))
                .cell("D\(row)", .number(line.1))
                .cell("E\(row)", .number(line.1 * 1.02))
                .formula("F\(row)", "ROUND(E\(row)*1.08,2)", cached: .number((line.1 * 1.02 * 1.08).rounded()))
        }
        let total = lines.count + 2
        builder = builder
            .cell("A\(total)", .text("Total"))
            .formula("B\(total)", "SUM(B2:B\(total - 1))", cached: .number(0))
            .formula("C\(total)", "SUM(C2:C\(total - 1))", cached: .number(0))
            .formula("D\(total)", "SUM(D2:D\(total - 1))", cached: .number(0))
            .formula("E\(total)", "SUM(E2:E\(total - 1))", cached: .number(0))
            .formula("F\(total)", "SUM(F2:F\(total - 1))", cached: .number(0))
            .sheet("Q4")
            .partPath("xl/worksheets/sheet2.xml", relationshipID: "rId2")
            .rows("A1", [
                [.text("Region"), .text("Actual"), .text("Plan")],
                [.text("EMEA"), .number(318_400), .number(300_000)],
                [.text("AMER"), .number(521_775), .number(510_000)],
                [.text("APAC"), .number(96_600), .number(105_000)],
            ])
            .sheet("Headcount")
            .partPath("xl/worksheets/sheet3.xml", relationshipID: "rId3")
            .rows("A1", [
                [.text("Team"), .text("Now"), .text("Plan")],
                [.text("Engineering"), .number(41), .number(48)],
                [.text("Design"), .number(6), .number(8)],
                [.text("Sales"), .number(19), .number(24)],
            ])
            .sheet("Assumptions")
            .partPath("xl/worksheets/sheet4.xml", relationshipID: "rId4")
            .rows("A1", [
                [.text("Name"), .text("Value")],
                [.text("Growth"), .number(0.08)],
                [.text("Attrition"), .number(0.11)],
            ])
            .definedName("GrowthRate", refersTo: "Assumptions!$B$2")
            .definedName("Q4Total", refersTo: "Q4!$B$2:$B$4")

        let workbook = try builder.build()
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets { tracker.noteSheetReplaced(sheet) }
        let url = root.appendingPathComponent("q4-budget.xlsx")
        try XLSXWriter.data(for: workbook, edits: tracker).write(to: url)
        print("demo workbook written to \(url.path)")
    }
}
