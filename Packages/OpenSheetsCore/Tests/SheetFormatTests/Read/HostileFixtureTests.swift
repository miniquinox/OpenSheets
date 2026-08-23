//
//  HostileFixtureTests.swift
//  SheetFormatTests
//
//  A1. `Fixtures/hostile/` — every file must be refused with a specific error, quickly, in
//  bounded memory. Except one, which must open.
//

import Foundation
import Testing

import MiniZip
import SheetFormat
import SheetModel
import TestSupport

@Suite("xlsx read — hostile input", .enabled(if: FixtureLibrary.isAvailable))
struct HostileFixtureTests {
    /// The per-case ceiling the corpus asks for. Every case currently lands three orders of
    /// magnitude under it; the point is that a regression which turns a rejection into a hang
    /// fails here rather than wedging CI.
    static let caseTimeout = Duration.seconds(2)

    /// How many bytes one hostile file may cause this reader to inflate.
    ///
    /// A work-done ceiling rather than a resident-memory one. Resident size is process-wide, and
    /// Swift Testing runs suites in parallel, so an RSS reading here would mostly measure whatever
    /// the perf suite happened to be doing — a gate that fails for reasons unrelated to its
    /// subject is a gate people learn to ignore (`WAVE-1-ADDENDUM.md` §8). Bytes charged to this
    /// read's own ``DecompressionBudget`` cannot be polluted by another test.
    ///
    /// 8 MB is generous next to the largest legitimate part in the hostile corpus (700 KB) and
    /// stingy next to the 200 MB a single un-capped inflation would cost.
    static let inflationCeiling = 8 * 1024 * 1024

    static var cases: [HostileExpectations.Case] {
        ((try? FixtureLibrary.hostileExpectations())?.cases ?? []).filter { FixtureLibrary.exists($0.file) }
    }

    @Test("is rejected with the error the corpus names", arguments: cases)
    func rejects(expectation: HostileExpectations.Case) async throws {
        let url = try FixtureLibrary.url(expectation.file)
        let budget = DecompressionBudget()
        let clock = ContinuousClock()
        let started = clock.now

        var thrown: SheetError?
        var opened: Workbook?
        do {
            // `read` is typed-throwing, so `error` is already a `SheetError` — nothing else can
            // come out of here, which is itself part of the contract.
            opened = try await XLSXReader.readWithDiagnostics(contentsOf: url, budget: budget).workbook
        } catch {
            thrown = error
        }

        let elapsed = MachineCalibration.seconds(clock.now - started)
        #expect(
            budget.used < Self.inflationCeiling,
            "\(expectation.file) inflated \(ByteCount.describe(budget.used))"
        )
        // A ceiling on *hanging*, not on speed. Scaled for an unoptimised build and for the load
        // this Mac is normally under, because the failure this guards against is an unbounded
        // loop and those do not finish in twelve seconds either.
        let ceiling = MachineCalibration.seconds(Self.caseTimeout)
            * PerfGuard.debugSlack * MachineLoad.sample().recommendedSlack
        #expect(
            elapsed < ceiling,
            "\(expectation.file) took \(String(format: "%.3f", elapsed))s; the ceiling is \(String(format: "%.3f", ceiling))s"
        )

        if expectation.expectsSuccess {
            #expect(thrown == nil, "\(expectation.file) must open, but threw \(thrown?.code ?? "")")
            #expect(opened != nil, "\(expectation.file) must open")
            return
        }

        let accepted = ([expectation.expectedError] + (expectation.alsoAcceptable ?? []))
            .compactMap { $0 }
            .joined(separator: " or ")
        guard let thrown else {
            Issue.record("\(expectation.file): expected \(accepted), nothing was thrown")
            return
        }
        let message = "\(expectation.file): expected \(accepted), got \(thrown.code)\n  \(thrown)"
        #expect(expectation.accepts(code: thrown.code), Comment(rawValue: message))
    }

    /// Every hostile fixture has an expectation, and every expectation has a fixture.
    ///
    /// This is what stops the reconciliation in `WAVE-1-ADDENDUM.md` §6 from rotting: a new
    /// hostile file with no entry, or an entry whose file was renamed, both fail here.
    @Test("the corpus and its expectation file agree on what exists")
    func expectationsCoverTheCorpus() throws {
        let expectations = try FixtureLibrary.hostileExpectations()
        let listed = Set(expectations.cases.map(\.file))
        let onDisk = Set(
            (try FileManager.default.contentsOfDirectory(atPath: try FixtureLibrary.url("hostile").path))
                .filter { $0.hasSuffix(".xlsx") || $0.hasSuffix(".xlsm") }
                .map { "hostile/\($0)" }
        )
        #expect(listed == onDisk, "unlisted: \(onDisk.subtracting(listed)); missing: \(listed.subtracting(onDisk))")
        #expect(expectations.count == expectations.cases.count, "the `count` field disagrees with `cases`")
    }

    /// Every code named in `expected-errors.json` is a code `SheetError` can actually produce.
    ///
    /// The addendum makes A0's enum the source of truth and hands A1 the reconciliation. A code
    /// string that no case emits would make a test that can never pass, so the mapping is checked
    /// against the enum itself rather than against a second hand-written list.
    @Test("every expected code is a real SheetError.code")
    func codesExist() throws {
        let known = Set(SheetErrorCodes.all)
        for expectation in try FixtureLibrary.hostileExpectations().cases {
            for code in ([expectation.expectedError] + (expectation.alsoAcceptable ?? [])).compactMap({ $0 }) {
                #expect(known.contains(code), "\(expectation.file): '\(code)' is not a SheetError.code")
            }
        }
    }

    // MARK: - The two behaviours the codes alone do not capture

    /// `zip-bomb-nested.xlsx` opens **and never inflates the bomb**.
    ///
    /// The addendum's §2 test. An eager reader that caps total decompressed bytes across the
    /// archive rejects a legitimate workbook; the correct behaviour is to keep every entry's
    /// compressed bytes and inflate only the parts actually parsed.
    @Test("a bomb nobody asked for is never inflated")
    func nestedBombIsNeverTouched() async throws {
        let (workbook, diagnostics) = try await XLSXReader.read(
            try FixtureLibrary.data("hostile/zip-bomb-nested.xlsx"),
            name: "hostile/zip-bomb-nested.xlsx"
        )
        #expect(workbook.sheets.count == 1)
        let payload = try #require(workbook.passthrough["xl/media/payload.zip"])
        #expect(payload.compressedData.count == 383, "the bomb must survive as stored bytes for the writer")

        // Every modelled part of this workbook inflates to well under 4 KB. If the bomb had been
        // touched, this number would be in the megabytes.
        #expect(
            diagnostics.inflatedBytes < 8192,
            "inflated \(ByteCount.describe(diagnostics.inflatedBytes)) — something inflated a part nobody asked for"
        )
        PerfGuard.expectWork(
            "read.lazyInflation.zipBombNested",
            value: Double(diagnostics.inflatedBytes),
            atMost: 8192,
            unit: .bytes,
            note: "bytes inflated while opening a workbook with a 1030:1 bomb in xl/media/"
        )
    }

    /// The XXE fixture parses nothing and reads nothing.
    ///
    /// Beyond the error code: no cell may end up holding the contents of `/etc/passwd`, and no
    /// connection may be attempted. The blanket DTD refusal is what makes both true, and the
    /// assertion is written against the *outcome* so a future relaxation of the policy cannot
    /// quietly pass.
    @Test("an external entity is never resolved")
    func externalEntitiesAreNeverResolved() async throws {
        let data = try FixtureLibrary.data("hostile/xxe-external-entity.xlsx")
        var thrown: SheetError?
        do {
            let workbook = try await XLSXReader.read(data, name: "xxe").workbook
            for sheet in workbook.sheets {
                sheet.cells.forEachCell(in: .entireSheet) { ref, cell in
                    if let text = cell.value.text {
                        #expect(!text.contains("root:"), "\(ref) holds the contents of a system file")
                        #expect(!text.contains("/bin/"), "\(ref) holds the contents of a system file")
                    }
                }
            }
        } catch {
            thrown = error
        }
        #expect(thrown?.code == "xml.doctype", "got \(thrown?.code ?? "no error")")
    }

    /// A malformed file names the part it failed in.
    ///
    /// "Could not open file" is not a diagnosis. The corpus says so explicitly.
    @Test("a parse failure names the part")
    func errorsNameThePart() async throws {
        do {
            _ = try await XLSXReader.read(
                try FixtureLibrary.data("hostile/malformed-xml.xlsx"), name: "malformed"
            )
            Issue.record("malformed-xml.xlsx parsed")
        } catch let error as SheetError {
            #expect("\(error)".contains("sheet1.xml"), "the message does not name the part: \(error)")
        }
    }
}

/// Every `SheetError.code` this build can emit.
///
/// Derived by asking one instance of each case for its code rather than by copying the strings,
/// so a renamed code shows up as a failing reconciliation test instead of as a silent
/// disagreement between the enum and the corpus.
enum SheetErrorCodes {
    static let all: [String] = samples.map(\.code)

    static let samples: [SheetError] = [
        .archiveTooLarge(decompressedBytes: 0, limit: 0),
        .archiveEntryTooLarge(path: "", declaredBytes: 0, limit: 0),
        .archiveCompressionRatioExceeded(path: "", ratio: 0, limit: 0),
        .archiveTooManyEntries(count: 0, limit: 0),
        .archivePathTraversal(entryName: ""),
        .archiveDuplicateEntry(name: ""),
        .archiveTruncated(detail: ""),
        .archiveMalformed(detail: ""),
        .archiveUnsupportedCompression(path: "", method: 0),
        .archiveEntryNotFound(path: ""),
        .archiveChecksumMismatch(path: "", expected: 0, actual: 0),
        .archiveNestingTooDeep(depth: 0, limit: 0),
        .xmlExternalEntityRejected(part: "", detail: ""),
        .xmlDocumentTypeRejected(part: ""),
        .xmlDepthExceeded(part: "", depth: 0, limit: 0),
        .xmlTooManyAttributes(part: "", count: 0, limit: 0),
        .xmlTokenTooLong(part: "", bytes: 0, limit: 0),
        .xmlMalformed(part: "", line: nil, detail: ""),
        .xmlInvalidEncoding(part: "", detail: ""),
        .sheetDimensionOutOfRange(sheet: "", rows: 0, columns: 0),
        .criticalPartMissing(path: ""),
        .criticalPartUnsupported(path: "", detail: ""),
        .workbookEncrypted,
        .unsupportedFileFormat(detail: ""),
        .workbookTooComplex(detail: ""),
        .invalidCellReference(text: ""),
        .cellReferenceOutOfRange(row: 0, column: 0),
        .rangeOutOfRange(range: "", detail: ""),
        .invalidSheetName(name: "", reason: ""),
        .duplicateSheetName(name: ""),
        .sheetNotFound(reference: ""),
        .invalidDefinedName(name: "", reason: ""),
        .unknownStyleID(rawValue: 0),
        .invalidNumberFormat(code: "", reason: ""),
        .invalidFormula(text: "", position: nil, reason: ""),
        .formulaTooLong(length: 0, limit: 0),
        .cellTextTooLong(ref: "", length: 0, limit: 0),
        .fileNotFound(path: ""),
        .fileNotReadable(path: "", underlying: ""),
        .fileTooLarge(path: "", bytes: 0, limit: 0),
        .writeRefused(reason: .encrypted),
        .internalInconsistency(detail: ""),
        .invalidArgument(name: "", reason: ""),
    ]
}
