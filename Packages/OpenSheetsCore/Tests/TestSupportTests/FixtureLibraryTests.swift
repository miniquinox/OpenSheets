import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("FixtureLibrary", .enabled(if: FixtureLibrary.isAvailable))
struct FixtureLibraryTests {
    @Test("the corpus is found by walking up from the source file")
    func corpusFound() throws {
        let root = try #require(FixtureLibrary.root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path))
        #expect(root.lastPathComponent == "Fixtures")
    }

    @Test("every category has fixtures with sidecars")
    func categoriesPopulated() {
        for category in FixtureLibrary.Category.allCases where category != .hostile {
            #expect(!FixtureLibrary.fixtures(in: category).isEmpty, "\(category.rawValue) has no sidecars")
        }
    }

    @Test("every sidecar in the corpus decodes")
    func everySidecarDecodes() throws {
        var decoded = 0
        for path in FixtureLibrary.allFixtures {
            let expected = try FixtureLibrary.expected(for: path)
            #expect(expected.file == path, "\(path): the sidecar names a different file (\(expected.file))")
            #expect(!expected.proves.isEmpty, "\(path): a fixture with no stated purpose is a fixture nobody trusts")
            decoded += 1
        }
        #expect(decoded >= 40, "the brief asks for at least 40 fixtures with validated sidecars")
    }

    @Test("an xlsx sidecar carries sheets, a csv sidecar carries a dialect and rows")
    func sidecarShapes() throws {
        for path in FixtureLibrary.allFixtures {
            let expected = try FixtureLibrary.expected(for: path)
            switch expected.kind {
            case .xlsx, .xlsm:
                #expect(expected.sheets != nil, "\(path): an xlsx sidecar with no sheets")
            case .csv:
                #expect(expected.dialect != nil, "\(path): a csv sidecar with no dialect")
                #expect(expected.rows != nil, "\(path): a csv sidecar with no rows")
            }
        }
    }

    @Test("the minimal fixture decodes to the value the README documents")
    func minimalFixture() throws {
        let expected = try FixtureLibrary.expected(for: "basic/minimal.xlsx")
        #expect(expected.kind == .xlsx)
        #expect(expected.resolvedDateSystem == .excel1900)
        let sheet = try #require(expected.sheets?.first)
        #expect(sheet.name == "Sheet1")
        #expect(sheet.usedRange == "A1:A1")
        #expect(sheet.cells?["A1"]?.expectedValue == .number(42))
    }

    @Test("the merged-cells fixture states the wider used range the addendum describes")
    func mergedCellsFixture() throws {
        let expected = try FixtureLibrary.expected(for: "structure/merged-cells.xlsx")
        let sheet = try #require(expected.sheets?.first)
        #expect(sheet.usedRange == "A1:F8")
        #expect(sheet.cells?.count == 4, "four cells, a used range of A1:F8 — that is the whole point")
        #expect(sheet.merges?.contains("A1:D1") == true)
    }

    @Test("cell flags in a sidecar map onto CellFlags")
    func flagDecoding() throws {
        let expected = try FixtureLibrary.expected(for: "formulas/external-link.xlsx")
        let sheet = try #require(expected.sheets?.first)
        let flagged = sheet.cells?.values.first { !($0.flags ?? []).isEmpty }
        let cell = try #require(flagged)
        #expect(cell.expectedFlags.contains(.externalLink))
    }

    @Test("the hostile expectations decode and cover every hostile fixture")
    func hostileExpectations() throws {
        let expectations = try FixtureLibrary.hostileExpectations()
        #expect(expectations.cases.count >= 20)
        if let declared = expectations.count {
            #expect(declared == expectations.cases.count, "the file's own count disagrees with its cases")
        }

        for entry in expectations.cases {
            #expect(entry.file.hasPrefix("hostile/"))
            #expect(FixtureLibrary.exists(entry.file), "\(entry.file) is listed but not on disk")
            #expect(entry.proves?.isEmpty == false, "\(entry.file) has no stated purpose")
        }
    }

    @Test("the nested zip bomb is the one hostile fixture that must open")
    func nestedZipBombOpens() throws {
        let expectations = try FixtureLibrary.hostileExpectations()
        let entry = try #require(expectations.expectation(for: "hostile/zip-bomb-nested.xlsx"))
        // Wave 1 addendum §2: a valid workbook that happens to park a bomb in an unmodelled part.
        #expect(entry.expectsSuccess)
        #expect(entry.mustNotHappen?.contains { $0.contains("xl/media/payload.zip") } == true)
    }

    @Test("accepts() honours the alsoAcceptable list")
    func alternativeCodes() throws {
        let expectations = try FixtureLibrary.hostileExpectations()
        let withAlternatives = expectations.cases.first { !($0.alsoAcceptable ?? []).isEmpty }
        let entry = try #require(withAlternatives)
        let alternative = try #require(entry.alsoAcceptable?.first)
        #expect(entry.accepts(code: alternative))
        #expect(!entry.accepts(code: "core.notImplemented"))
    }

    @Test("the perf fixtures that are generated rather than committed report absent, not broken")
    func generatedFixtures() {
        // `Fixtures/perf/1m-cells.xlsx` and `perf/2gb.csv` are git-ignored on purpose.
        let declared = Set(FixtureLibrary.fixtures(in: .perf))
        let present = Set(FixtureLibrary.availableFixtures.filter { $0.hasPrefix("perf/") })
        #expect(present.isSubset(of: declared))
        #expect(!declared.isEmpty)
    }

    @Test("a missing fixture throws rather than returning empty data")
    func missingFixture() {
        #expect(throws: FixtureLibrary.FixtureError.self) {
            _ = try FixtureLibrary.data("basic/there-is-no-such-file.xlsx")
        }
    }
}
