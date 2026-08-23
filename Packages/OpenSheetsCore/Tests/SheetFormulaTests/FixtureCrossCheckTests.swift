import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// Evaluates the 69 formulas from `Fixtures/formulas/functions.xlsx` and checks our answers
/// against the values a **different** spreadsheet engine computed for them.
///
/// This is the other half of the `functions.tsv` gate. That corpus is ours: the expectations
/// were written by hand, so it proves we agree with ourselves and with the spec as we read it.
/// This one proves we agree with a real spreadsheet application on the same formulas, using
/// A7's cached values as ground truth — and it exercises the *stored* `_xlfn.` spellings,
/// because that is what the file actually contains.
///
/// It reads `functions.xlsx.expected.json` rather than the workbook itself: reading the `.xlsx`
/// is A1's job and is not landed yet, while the sidecar carries the same formulas and the same
/// cached values.
struct FixtureCrossCheckTests {
    struct Expectation {
        var address: String
        var formula: String
        var type: String
        var value: Any?
    }

    /// The repository's `Fixtures` directory, found by walking up from this file.
    static var fixturesDirectory: URL? {
        var url = URL(filePath: #filePath)
        for _ in 0 ..< 8 {
            url = url.deletingLastPathComponent()
            let candidate = url.appending(path: "Fixtures")
            if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) { return candidate }
        }
        return nil
    }

    static func loadCalcFormulas() throws -> [Expectation] {
        guard let directory = fixturesDirectory else { return [] }
        let url = directory.appending(path: "formulas/functions.xlsx.expected.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sheets = root?["sheets"] as? [[String: Any]] ?? []
        guard let calc = sheets.first(where: { $0["name"] as? String == "Calc" }),
              let cells = calc["cells"] as? [String: Any]
        else { return [] }

        var result: [Expectation] = []
        for (address, raw) in cells {
            guard let entry = raw as? [String: Any],
                  let formula = entry["formula"] as? String,
                  let type = entry["type"] as? String
            else { continue }
            result.append(Expectation(address: address, formula: formula, type: type, value: entry["value"]))
        }
        return result.sorted { $0.address < $1.address }
    }

    @Test func theFixtureIsPresentAndHasEveryFunctionFamily() throws {
        let formulas = try FixtureCrossCheckTests.loadCalcFormulas()
        try #require(!formulas.isEmpty, "Fixtures/formulas/functions.xlsx.expected.json was not found")
        #expect(formulas.count >= 60, "the fixture should carry about 69 formulas, found \(formulas.count)")
    }

    @Test func weAgreeWithTheOtherEngineOnEveryFixtureFormula() throws {
        let formulas = try FixtureCrossCheckTests.loadCalcFormulas()
        try #require(!formulas.isEmpty)

        let workbook = TestWorkbook.make()
        let engine = FormulaEngine(options: TestWorkbook.options)
        var failures: [String] = []

        for expectation in formulas {
            guard let ref = CellRef(a1: expectation.address) else { continue }
            let origin = SheetCell(sheet: TestWorkbook.calcSheetID, ref: ref)
            let outcome = engine.evaluate(expectation.formula, at: origin, in: workbook)
            guard case let .value(value) = outcome else {
                failures.append("\(expectation.address) =\(expectation.formula): unsupported")
                continue
            }
            if let problem = FixtureCrossCheckTests.mismatch(value, expectation) {
                failures.append("\(expectation.address) =\(expectation.formula): \(problem)")
            }
        }
        let report = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "\(failures.count) fixture formulas disagreed:\n\(report)")
    }

    static func mismatch(_ value: CellValue, _ expectation: Expectation) -> String? {
        switch expectation.type {
        case "number":
            guard let wanted = expectation.value as? Double else { return "the fixture has no number" }
            guard case let .number(actual) = value else { return "expected \(wanted), got \(value)" }
            guard ExcelNumber.equal(actual, wanted) else { return "expected \(wanted), got \(actual)" }
        case "text":
            guard let wanted = expectation.value as? String else { return "the fixture has no text" }
            guard case let .text(actual) = value else { return "expected \"\(wanted)\", got \(value)" }
            guard actual == wanted else { return "expected \"\(wanted)\", got \"\(actual)\"" }
        case "boolean":
            guard let wanted = expectation.value as? Bool else { return "the fixture has no boolean" }
            guard case let .boolean(actual) = value else { return "expected \(wanted), got \(value)" }
            guard actual == wanted else { return "expected \(wanted), got \(actual)" }
        case "error":
            guard let wanted = expectation.value as? String else { return "the fixture has no error token" }
            guard case let .error(actual) = value else { return "expected \(wanted), got \(value)" }
            guard actual.rawValue == wanted else { return "expected \(wanted), got \(actual.rawValue)" }
        default:
            return nil
        }
        return nil
    }

    /// The fixture stores newer functions with their `_xlfn.` prefix, which is the only place
    /// in the test suite where the prefixed spellings arrive from a real file rather than from
    /// a string we wrote ourselves.
    @Test func theFixtureReallyDoesUseTheStoredSpellings() throws {
        let formulas = try FixtureCrossCheckTests.loadCalcFormulas()
        try #require(!formulas.isEmpty)
        let prefixed = formulas.filter { $0.formula.contains("_xlfn.") }
        #expect(prefixed.count >= 9, "WAVE-1-ADDENDUM §3 lists nine; found \(prefixed.count)")
        for expectation in prefixed {
            #expect(
                throws: Never.self,
                "\(expectation.formula) should parse"
            ) { try FormulaSyntax.parse(expectation.formula) }
        }
    }
}
