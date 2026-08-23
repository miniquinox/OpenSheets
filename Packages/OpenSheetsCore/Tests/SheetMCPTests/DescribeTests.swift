import Foundation
@testable import SheetMCP
import SheetModel
import Testing

/// `describe` — the acceptance case, the header heuristic, and the token budget.
///
/// The budget assertions are the point of this suite. `describe` exists so an agent does not
/// have to read a workbook to understand it, and a `describe` that costs 5,000 tokens has not
/// solved the problem it was built for — it has moved it. So the size of the output is asserted
/// as a property, on real shapes, with a pessimistic estimator (see ``TokenBudget``).
@Suite struct DescribeTests {
    // MARK: - The budget

    /// **Acceptance: a 50,000-row workbook describes in under 800 tokens.**
    ///
    /// The structural reason it fits is that nothing in the output scales with rows — the same
    /// eight-column sheet at 50 rows and at 50,000 rows produces the same number of lines. The
    /// test asserts the budget *and* that invariance, because the second is what will still be
    /// true after somebody adds a field.
    @Test func fiftyThousandRowsFitInEightHundredTokens() throws {
        let big = try Fixtures.salesLedger(rows: 50000)
        let small = try Fixtures.salesLedger(rows: 50)
        let profiler = SheetProfiler()

        let bigText = ProfileRenderer.render(profiler.profile(big, path: "/w/sales.xlsx"))
        let smallText = ProfileRenderer.render(profiler.profile(small, path: "/w/sales.xlsx"))

        let tokens = TokenBudget.estimate(bigText)
        #expect(tokens < 800, "describe cost \(tokens) tokens (\(bigText.utf8.count) bytes):\n\(bigText)")
        #expect(bigText.split(separator: "\n").count == smallText.split(separator: "\n").count,
                "the output is not row-invariant.\n--- 50,000 rows ---\n\(bigText)\n--- 50 rows ---\n\(smallText)")
        // Sanity: it did read the whole thing.
        #expect(bigText.contains("50,001 rows"), "the header row plus 50,000 data rows")
        #expect(bigText.contains("header=row 1"))
    }

    /// Every fixture shape stays inside the budget, and none of them is empty.
    ///
    /// Run as a table so a shape added later is one row rather than a new test — and so the
    /// failure names the shape that blew the budget.
    @Test(arguments: DescribeTests.allShapes) func everyShapeStaysInBudget(shape: Shape) throws {
        let workbook = try shape.build()
        let text = ProfileRenderer.render(SheetProfiler().profile(workbook, path: "/w/\(shape.rawValue).xlsx"))
        let tokens = TokenBudget.estimate(text)
        #expect(tokens < 800, "\(shape.rawValue) cost \(tokens) tokens:\n\(text)")
        #expect(!text.isEmpty)
    }

    // MARK: - Header detection

    /// A header on row 1, a header on row 4, and a sheet with none — the three answers.
    @Test func findsTheHeaderRowWhereverItIs() throws {
        let profiler = SheetProfiler()

        let ledger = try Fixtures.salesLedger(rows: 200)
        #expect(profiler.profile(ledger.sheets[0], styles: ledger.styles).headerRow == 0)

        let report = try Fixtures.reportWithTitle()
        let reportProfile = profiler.profile(report.sheets[0], styles: report.styles)
        #expect(reportProfile.headerRow == 3, "a title row and a blank row above the header")

        let matrix = try Fixtures.headerless()
        #expect(profiler.profile(matrix.sheets[0], styles: matrix.styles).headerRow == nil)
    }

    /// The case a "the first row is mostly text" heuristic gets wrong.
    ///
    /// Both sheets are entirely text. The only difference is that in one of them the first
    /// row's values reappear further down — which is what a *value* does and what a *name* does
    /// not. Getting these two right in opposite directions is the whole argument for the
    /// recurrence term in the score.
    @Test func textOnlyDataIsNotMistakenForAHeader() throws {
        let profiler = SheetProfiler()

        let anonymous = try Fixtures.textOnlyWithoutHeader()
        #expect(profiler.profile(anonymous.sheets[0], styles: anonymous.styles).headerRow == nil,
                "row 1 repeats below, so it is data")

        let labelled = try Fixtures.textOnlyWithHeader()
        #expect(profiler.profile(labelled.sheets[0], styles: labelled.styles).headerRow == 0)
    }

    /// A marginal answer is reported as marginal.
    @Test func headerConfidenceIsReported() throws {
        let ledger = try Fixtures.salesLedger(rows: 100)
        let profile = SheetProfiler().profile(ledger.sheets[0], styles: ledger.styles)
        #expect(profile.headerConfidence > 0.7, "a clean typed table should be a confident answer")
        let text = ProfileRenderer.render(profile).joined(separator: "\n")
        #expect(text.contains("header=row 1"))
        #expect(!text.contains("header=row 1?"), "no hedge on a confident answer")
    }

    // MARK: - Column types

    /// Dates, money, percentages, integers, text, booleans and formulas, each named correctly.
    ///
    /// The date and percentage cases are the ones that matter: both are stored as plain numbers
    /// and only the cell's number format says which. A profiler that reported `Date` as `number`
    /// would be telling an agent to do arithmetic on 45,231.
    @Test func inferscolumnTypesFromValuesAndFormats() throws {
        let ledger = try Fixtures.salesLedger(rows: 500)
        let profile = SheetProfiler().profile(ledger.sheets[0], styles: ledger.styles)
        let byHeader = Dictionary(uniqueKeysWithValues: profile.columns.map { ($0.header ?? "", $0) })

        #expect(byHeader["Date"]?.type == .date)
        #expect(byHeader["Region"]?.type == .text)
        #expect(byHeader["Units"]?.type == .integer)
        #expect(byHeader["Price"]?.type == .currency)
        #expect(byHeader["Margin"]?.type == .percentage)
        #expect(byHeader["Active"]?.type == .boolean)
        #expect(byHeader["Revenue"]?.formulaCount ?? 0 > 0)
        #expect(byHeader["Revenue"]?.formulaSample?.contains("*") == true)
    }

    /// Nulls are counted against the body rows, not against the populated ones.
    @Test func countsNullsAgainstTheBodyNotTheData() throws {
        let sparse = try Fixtures.sparse()
        let profile = SheetProfiler().profile(sparse.sheets[0], styles: sparse.styles)
        let note = try #require(profile.columns.first { $0.header == "note" })
        #expect(note.populatedCount == 4, "200 rows, one value every 50")
        #expect(note.nullCount == 196)

        let code = try #require(profile.columns.first { $0.header == "code" })
        #expect(code.nullCount == 0)
    }

    /// A column that is half numbers and half text is called mixed, not one of them.
    @Test func aMixedColumnSaysSo() throws {
        let imported = try Fixtures.mixedTypes()
        let profile = SheetProfiler().profile(imported.sheets[0], styles: imported.styles)
        let amount = try #require(profile.columns.first { $0.header == "amount" })
        #expect(amount.type == .mixed)
        #expect(amount.purity < 0.8)
    }

    /// Errors are surfaced as errors rather than folded into "text".
    @Test func errorCellsAreNamed() throws {
        let broken = try Fixtures.withErrors()
        let profile = SheetProfiler().profile(broken.sheets[0], styles: broken.styles)
        let result = try #require(profile.columns.first { $0.header == "result" })
        #expect(result.type == .error)
        #expect(result.errorCount == 10)
    }

    /// Past the column cap, the rest are counted rather than dropped.
    @Test func widerThanTheCapReportsTheRemainder() throws {
        let wide = try Fixtures.wide(columns: 60)
        let profile = SheetProfiler().profile(wide.sheets[0], styles: wide.styles)
        #expect(profile.columns.count == 40)
        #expect(profile.omittedColumnCount == 20)
        let text = ProfileRenderer.render(profile).joined(separator: "\n")
        #expect(text.contains("20 more columns not profiled"))
    }

    /// An empty sheet says it is empty rather than producing nothing.
    @Test func anEmptySheetIsDescribedAsEmpty() {
        let profile = SheetProfiler().profile(Fixtures.empty(), path: "/w/empty.xlsx")
        let text = ProfileRenderer.render(profile)
        #expect(text.contains("Sheet1: empty"))
    }

    /// Hidden sheets are described and marked, not skipped.
    @Test func hiddenSheetsAreMarkedNotHidden() throws {
        let workbook = try Fixtures.multiSheet()
        let text = ProfileRenderer.render(SheetProfiler().profile(workbook, path: "/w/multi.xlsx"))
        #expect(text.contains("Scratch"))
        #expect(text.contains("hidden"))
    }

    // MARK: - Through the tool

    /// The tool wraps its output, names the file, and can be narrowed to one sheet.
    @Test @MainActor func theToolWrapsAndScopes() async throws {
        let harness = try Harness.make("describe-tool")
        let path = try harness.install(try Fixtures.multiSheet(), as: "multi.xlsx")

        let whole = await harness.call("describe", ["path": .string(path)])
        #expect(!whole.isError, "\(whole.text)")
        #expect(whole.text.hasPrefix("<untrusted-spreadsheet-content"))
        #expect(whole.text.contains("Summary"))
        #expect(whole.text.contains("Data"))

        let scoped = await harness.call("describe", ["path": .string(path), "sheet": .string("Data")])
        #expect(!scoped.isError, "\(scoped.text)")
        #expect(scoped.text.contains("Data"))
        #expect(!scoped.text.contains("Metric"), "the Summary sheet's header should not appear")
    }

    /// A sheet name that is not there lists the ones that are.
    @Test @MainActor func anUnknownSheetNamesTheRealOnes() async throws {
        let harness = try Harness.make("describe-unknown")
        let path = try harness.install(try Fixtures.multiSheet(), as: "multi.xlsx")
        let output = await harness.call("describe", ["path": .string(path), "sheet": .string("Nope")])
        #expect(output.isError)
        #expect(output.text.contains("Summary, Data, Scratch"), "\(output.text)")
    }

    /// `preview: true` is accepted on a read-only tool and changes nothing.
    @Test @MainActor func previewIsAcceptedOnAReadOnlyTool() async throws {
        let harness = try Harness.make("describe-preview")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let plain = await harness.call("describe", ["path": .string(path)])
        let preview = await harness.call("describe", ["path": .string(path), "preview": .bool(true)])
        #expect(plain.text == preview.text)
    }

    // MARK: - The shape table

    /// The fixture shapes the budget runs over. Ten of them, deliberately unalike.
    enum Shape: String, CaseIterable, Sendable {
        case fiftyThousandRows
        case titleThenHeader
        case headerless
        case textOnlyWithoutHeader
        case textOnlyWithHeader
        case mixedTypes
        case wide
        case sparse
        case errors
        case multiSheet
        case empty
        case budget

        func build() throws -> Workbook {
            switch self {
            case .fiftyThousandRows: try Fixtures.salesLedger(rows: 50000)
            case .titleThenHeader: try Fixtures.reportWithTitle()
            case .headerless: try Fixtures.headerless()
            case .textOnlyWithoutHeader: try Fixtures.textOnlyWithoutHeader()
            case .textOnlyWithHeader: try Fixtures.textOnlyWithHeader()
            case .mixedTypes: try Fixtures.mixedTypes()
            case .wide: try Fixtures.wide(columns: 60)
            case .sparse: try Fixtures.sparse()
            case .errors: try Fixtures.withErrors()
            case .multiSheet: try Fixtures.multiSheet()
            case .empty: Fixtures.empty()
            case .budget: try Fixtures.budget()
            }
        }
    }

    static let allShapes = Shape.allCases
}
