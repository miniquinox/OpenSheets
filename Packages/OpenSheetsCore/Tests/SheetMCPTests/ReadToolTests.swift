import Foundation
@testable import SheetMCP
import SheetModel
import Testing

/// `read_range`, `find`, and the range grammar they share.
@Suite struct ReadToolTests {
    // MARK: - Range parsing

    /// Every spelling an agent is likely to produce resolves to the same rectangle.
    @Test @MainActor func theRangeGrammarAcceptsWhatAgentsWrite() async throws {
        let harness = try Harness.make("range-grammar")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let workbook = try await harness.reload(path)

        let plain = try RangeSelector.target(in: workbook, sheet: nil, range: "A1:C3", tool: "t")
        let qualified = try RangeSelector.target(in: workbook, sheet: nil, range: "Budget!A1:C3", tool: "t")
        let quoted = try RangeSelector.target(in: workbook, sheet: nil, range: "'Budget'!A1:C3", tool: "t")
        let absolute = try RangeSelector.target(in: workbook, sheet: nil, range: "$A$1:$C$3", tool: "t")
        let reversed = try RangeSelector.target(in: workbook, sheet: nil, range: "C3:A1", tool: "t")
        #expect(plain.range == qualified.range)
        #expect(plain.range == quoted.range)
        #expect(plain.range == absolute.range)
        #expect(reversed.range == plain.range, "a rectangle named corner-first is the same rectangle")
    }

    /// Whole-column and whole-row references are clamped to the used range.
    ///
    /// `A:A` is 1,048,576 cells. An agent that wrote it meant "that column", and answering it
    /// literally would be a million blanks and a truncation notice.
    @Test @MainActor func openReferencesAreClampedToTheUsedRange() async throws {
        let harness = try Harness.make("open-refs")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let workbook = try await harness.reload(path)

        let columns = try RangeSelector.target(in: workbook, sheet: nil, range: "A:B", tool: "t")
        #expect(columns.wasClamped)
        #expect(columns.range.rowCount == 6, "the used range is six rows")
        #expect(columns.range.columnCount == 2)

        let rows = try RangeSelector.target(in: workbook, sheet: nil, range: "2:3", tool: "t")
        #expect(rows.wasClamped)
        #expect(rows.range.rowCount == 2)
        #expect(rows.range.columnCount == 4)
    }

    /// A sheet named twice, differently, is a caller mistake worth reporting.
    @Test @MainActor func contradictorySheetArgumentsAreRefused() async throws {
        let harness = try Harness.make("contradiction")
        let path = try harness.install(try Fixtures.multiSheet(), as: "multi.xlsx")
        let output = await harness.call("read_range", [
            "path": .string(path), "sheet": .string("Summary"), "range": .string("Data!A1:B2"),
        ])
        #expect(output.isError)
        #expect(output.text.contains("Summary"))
        #expect(output.text.contains("Data"))
    }

    /// `A1:C` is a typo, not a shorthand, and guessing at it is how a tool deletes the wrong rows.
    @Test @MainActor func aHalfOpenReferenceIsRejected() async throws {
        let harness = try Harness.make("half-open")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("read_range", ["path": .string(path), "range": .string("A1:C")])
        #expect(output.isError)
        #expect(output.text.contains("ref.invalid"))
    }

    // MARK: - Compact reads

    /// Compact output is TSV with a column header row and a 1-based row label on every line.
    ///
    /// The row label is what makes a read addressable: an agent that spots a bad value on the
    /// seventh line of the output needs to know it is row 412, and counting lines is the kind of
    /// arithmetic that goes wrong silently.
    @Test @MainActor func compactOutputIsAddressable() async throws {
        let harness = try Harness.make("compact")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("read_range", ["path": .string(path), "range": .string("A1:D2")])
        #expect(!output.isError, "\(output.text)")

        let lines = output.text.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0 == "\tA\tB\tC\tD" })
        #expect(lines.contains { $0.hasPrefix("1\tItem\tQ1\tQ2\tTotal") })
        #expect(lines.contains { $0.hasPrefix("2\tRent\t100\t110\t") })
    }

    /// `formulas: true` shows the formula rather than the cached value.
    @Test @MainActor func formulasCanBeShownInsteadOfValues() async throws {
        let harness = try Harness.make("compact-formulas")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let values = await harness.call("read_range", ["path": .string(path), "range": .string("D2")])
        #expect(!values.text.contains("=SUM"))

        let formulas = await harness.call("read_range", [
            "path": .string(path), "range": .string("D2"), "formulas": .bool(true),
        ])
        #expect(formulas.text.contains("=SUM(B2:C2)"), "\(formulas.text)")
    }

    /// Detailed output carries formatting an agent might need to match.
    @Test @MainActor func detailedOutputCarriesFormatting() async throws {
        let harness = try Harness.make("detailed")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        _ = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1:D1"), "bold": .bool(true),
            "numberFormat": .string("General"),
        ])

        let output = await harness.call("read_range", [
            "path": .string(path), "range": .string("A1:B2"), "format": .string("detailed"),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains(#""bold":true"#), "\(output.text)")
        #expect(output.text.contains(#""ref":"A1""#))
    }

    /// A read past the row budget pages, and says exactly how to continue.
    @Test @MainActor func largeReadsPageAndSayHowToContinue() async throws {
        let harness = try Harness.make("paging")
        let path = try harness.install(try Fixtures.salesLedger(rows: 300), as: "sales.xlsx")

        let first = await harness.call("read_range", [
            "path": .string(path), "range": .string("A1:H300"), "maxRows": .integer(50),
        ])
        #expect(!first.isError, "\(first.text)")
        #expect(first.text.contains("more rows; call again with startRow=51"), "\(first.text.suffix(200))")

        let second = await harness.call("read_range", [
            "path": .string(path), "range": .string("A1:H300"), "maxRows": .integer(50),
            "startRow": .integer(51),
        ])
        #expect(!second.isError, "\(second.text)")
        #expect(second.text.contains("A51:H100"), "\(second.text.prefix(200))")
    }

    /// The cell budget caps a read even when `maxRows` is generous.
    @Test @MainActor func theCellBudgetCapsAWideRead() async throws {
        let harness = try Harness.make("cell-budget")
        let path = try harness.install(try Fixtures.wide(columns: 60), as: "wide.xlsx")
        let output = await harness.call("read_range", [
            "path": .string(path), "range": .string("A1:BH6"), "maxRows": .integer(100_000),
        ])
        #expect(!output.isError, "\(output.text)")
    }

    // MARK: - find

    /// `find` returns references, not contents.
    @Test @MainActor func findReturnsReferencesNotContents() async throws {
        let harness = try Harness.make("find")
        let path = try harness.install(try Fixtures.salesLedger(rows: 400), as: "sales.xlsx")

        let output = await harness.call("find", [
            "path": .string(path), "query": .string("North"), "match": .string("exact"),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("match"))
        #expect(output.text.contains("B2"), "\(output.text.prefix(200))")
        #expect(!output.text.contains("=North"), "values are off by default")
        // The whole point: 80 matches cost a list of refs, not 80 rows of data.
        #expect(output.text.utf8.count < 4000, "the result was \(output.text.utf8.count) bytes")
    }

    /// Formula search finds what a value search cannot.
    @Test @MainActor func findCanSearchFormulaText() async throws {
        let harness = try Harness.make("find-formulas")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let values = await harness.call("find", ["path": .string(path), "query": .string("SUM")])
        #expect(values.text.contains("no matches"))

        let formulas = await harness.call("find", [
            "path": .string(path), "query": .string("SUM"), "in": .string("formulas"),
        ])
        #expect(!formulas.isError, "\(formulas.text)")
        #expect(formulas.text.contains("D2"))
    }

    /// A regular expression is supported, and a bad one is reported as a bad argument.
    @Test @MainActor func regexSearchAndItsFailureMode() async throws {
        let harness = try Harness.make("find-regex")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let matched = await harness.call("find", [
            "path": .string(path), "query": .string("^(Rent|Cloud)$"), "match": .string("regex"),
        ])
        #expect(!matched.isError, "\(matched.text)")
        #expect(matched.text.contains("2 matches"), "\(matched.text)")

        let broken = await harness.call("find", [
            "path": .string(path), "query": .string("[unclosed"), "match": .string("regex"),
        ])
        #expect(broken.isError)
        #expect(broken.text.contains("tool.invalidArguments"))
    }

    /// A search over the whole workbook groups its answers by sheet.
    @Test @MainActor func findGroupsBySheet() async throws {
        let harness = try Harness.make("find-sheets")
        let path = try harness.install(try Fixtures.multiSheet(), as: "multi.xlsx")
        let output = await harness.call("find", ["path": .string(path), "query": .string("S1")])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("Data:"))
    }

    /// Beyond the limit, the rest are counted rather than dropped.
    @Test @MainActor func findCountsWhatItDoesNotList() async throws {
        let harness = try Harness.make("find-limit")
        let path = try harness.install(try Fixtures.salesLedger(rows: 400), as: "sales.xlsx")
        let output = await harness.call("find", [
            "path": .string(path), "query": .string("North"), "match": .string("exact"), "limit": .integer(5),
        ])
        #expect(output.text.contains("more not listed"), "\(output.text)")
    }

    /// Nothing found is a plain answer, not an error.
    @Test @MainActor func findingNothingIsNotAnError() async throws {
        let harness = try Harness.make("find-nothing")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("find", ["path": .string(path), "query": .string("zzzz")])
        #expect(!output.isError)
        #expect(output.text.contains("no matches"))
    }

    // MARK: - Formats and values

    /// Dates come back as ISO-8601, not as the serial number they are stored as.
    @Test func datesAreRenderedAsDates() throws {
        var styles = StyleTable()
        let dateStyle = styles.intern(Fixtures.style(numberFormatID: 14))
        let cell = Cell(value: .number(45658), styleID: dateStyle)
        #expect(CellText.plain(cell, styles: styles) == "2025-01-01")
    }

    /// A number keeps the precision the file has and loses the noise Swift adds.
    @Test func numbersAvoidBinaryNoise() {
        #expect(CellText.number(0.1 + 0.2) == "0.3")
        #expect(CellText.number(1) == "1")
        #expect(CellText.number(-1.5) == "-1.5")
        #expect(CellText.approximate(1_999_660.2400000105) == "1999660.24")
    }

    /// A CSV opens, describes and reads like anything else.
    @Test @MainActor func delimitedFilesWorkToo() async throws {
        let harness = try Harness.make("csv")
        let path = harness.workspace.appendingPathComponent("data.csv").path(percentEncoded: false)
        try Data("name,score\nAda,10\nGrace,20\n".utf8).write(to: URL(fileURLWithPath: path))

        let describe = await harness.call("describe", ["path": .string(path)])
        #expect(!describe.isError, "\(describe.text)")
        #expect(describe.text.contains("header=row 1"))

        let write = await harness.call("write_range", [
            "path": .string(path), "range": .string("B2"), "values": .array([.array([.integer(99)])]),
        ])
        #expect(!write.isError, "\(write.text)")
        let contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(contents.contains("Ada,99"), "\(contents)")
    }

    /// A file extension we do not handle is refused before anything is read.
    @Test @MainActor func unsupportedExtensionsAreRefusedEarly() async throws {
        let harness = try Harness.make("bad-extension")
        let path = harness.workspace.appendingPathComponent("notes.rtf").path(percentEncoded: false)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let output = await harness.call("describe", ["path": .string(path)])
        #expect(output.isError)
        #expect(output.text.contains("workbook.unsupportedFormat"))
    }
}
