import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// The table test: every row of `Resources/functions.tsv` evaluated and checked.
///
/// The corpus is the acceptance gate for function coverage, coercion, and error kinds. Rows
/// were written by hand or computed with independent arithmetic — never captured from this
/// engine's own output — so a regression shows up as a failure rather than as a quietly
/// updated snapshot.
struct FunctionTableTests {
    /// One row of the corpus.
    struct Row {
        var formula: String
        var expected: String
        var note: String
        var line: Int
    }

    /// Reads the corpus, from the test bundle when there is one and from the source tree
    /// otherwise.
    ///
    /// Both paths are kept because they fail in different situations: `Bundle.module` needs
    /// the resource declaration in `Package.swift`, and `#filePath` needs the source tree to
    /// still be next to the binary. Whichever is available wins.
    static func loadCorpus() throws -> [Row] {
        let bundled = Bundle.module.url(forResource: "functions", withExtension: "tsv", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "functions", withExtension: "tsv")
        let url = bundled ?? URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Resources/functions.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [Row] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { continue }
            rows.append(Row(
                formula: String(fields[0]),
                expected: String(fields[1]),
                note: fields.count > 2 ? String(fields[2]) : "",
                line: offset + 1
            ))
        }
        return rows
    }

    @Test func corpusIsLargeEnough() throws {
        let rows = try FunctionTableTests.loadCorpus()
        #expect(rows.count >= 600, "the brief asks for at least 600 rows; found \(rows.count)")
    }

    @Test func everyRowEvaluatesToItsExpectedValue() throws {
        let workbook = TestWorkbook.make()
        let engine = FormulaEngine(options: TestWorkbook.options)
        var failures: [String] = []

        for row in try FunctionTableTests.loadCorpus() {
            let outcome = engine.evaluate(row.formula, at: TestWorkbook.origin, in: workbook)
            guard let problem = FunctionTableTests.mismatch(outcome, expected: row.expected) else { continue }
            failures.append("line \(row.line): =\(row.formula) — \(problem) [\(row.note)]")
        }
        let report = failures.prefix(40).joined(separator: "\n")
        #expect(failures.isEmpty, "\(failures.count) rows failed:\n\(report)")
    }

    /// Compares an outcome against the corpus's encoding, returning a description of the
    /// disagreement or `nil` when they match.
    ///
    /// Numbers compare at 15 significant digits, because that is the precision Excel shows and
    /// the precision the expectations were written to. Comparing bit-for-bit would fail on
    /// `SQRT(2)` for reasons that have nothing to do with correctness.
    static func mismatch(_ outcome: CellOutcome, expected: String) -> String? {
        let kind = expected.prefix(2)
        let body = String(expected.dropFirst(2))

        if kind == "u:" {
            guard case .keepCached = outcome else { return "expected unsupported, got \(outcome)" }
            return nil
        }
        guard case let .value(value) = outcome else {
            if case let .keepCached(reason) = outcome { return "unexpectedly unsupported: \(reason.message)" }
            return "expected a value"
        }

        switch kind {
        case "n:":
            guard let wanted = Double(body) else { return "corpus row has an unparseable number '\(body)'" }
            guard case let .number(actual) = value else { return "expected \(wanted), got \(value)" }
            guard ExcelNumber.equal(actual, wanted) else { return "expected \(wanted), got \(actual)" }
        case "s:":
            guard case let .text(actual) = value else { return "expected \"\(body)\", got \(value)" }
            guard actual == body else { return "expected \"\(body)\", got \"\(actual)\"" }
        case "b:":
            guard case let .boolean(actual) = value else { return "expected \(body), got \(value)" }
            guard actual == (body == "TRUE") else { return "expected \(body), got \(actual)" }
        case "e:":
            guard case let .error(actual) = value else { return "expected \(body), got \(value)" }
            guard actual.rawValue == body else { return "expected \(body), got \(actual.rawValue)" }
        case "z:":
            guard case .empty = value else { return "expected a blank, got \(value)" }
        default:
            return "corpus row has an unknown expectation prefix '\(kind)'"
        }
        return nil
    }

    @Test func everyImplementedFunctionAppearsInTheCorpus() throws {
        let corpus = try FunctionTableTests.loadCorpus()
        let text = corpus.map(\.formula).joined(separator: "\n").uppercased()
        var missing: [String] = []
        for name in FunctionCatalog.implementedFunctions where !text.contains(name + "(") {
            missing.append(name)
        }
        let names = missing.sorted().joined(separator: ", ")
        #expect(missing.isEmpty, "functions with no corpus row: \(names)")
    }

    @Test func catalogueSizeIsPinned() {
        // The exact number, not a floor. This was `>= 120` — which stayed green while the
        // catalogue grew to 203, so the docs went on claiming "~120 functions" with a passing
        // test behind them. A floor cannot catch a function quietly disappearing either, as long
        // as enough remain. If you add or remove one, update this and say so in the commit.
        #expect(FunctionCatalog.implementedCount == 203)
        // Nothing may be in both lists: a function we implement is not "known unimplemented".
        let overlap = Set(FunctionCatalog.implementedFunctions)
            .intersection(FunctionCatalog.knownUnimplemented)
        #expect(overlap.isEmpty, "in both catalogues: \(overlap.sorted().joined(separator: ", "))")
    }
}
