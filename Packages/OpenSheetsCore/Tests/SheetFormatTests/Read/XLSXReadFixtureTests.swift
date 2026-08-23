//
//  XLSXReadFixtureTests.swift
//  SheetFormatTests
//
//  A1 owns `Tests/SheetFormatTests/Read/**`. The golden corpus, asserted against its sidecars.
//

import Foundation
import Testing

import MiniZip
import SheetFormat
import SheetModel
import TestSupport

@Suite("xlsx read — the golden corpus", .enabled(if: FixtureLibrary.isAvailable))
struct XLSXReadFixtureTests {
    /// Every `.xlsx`/`.xlsm` fixture with a sidecar, driven from the corpus rather than a list.
    ///
    /// A7 adds fixtures; a suite that has to be edited to notice them is a suite that stops
    /// noticing them.
    static var workbooks: [String] {
        FixtureLibrary.availableFixtures.filter {
            $0.hasSuffix(".xlsx") || $0.hasSuffix(".xlsm") || $0.hasSuffix(".xltx")
        }
    }

    /// The corpus minus `perf/1m-cells.xlsx`.
    ///
    /// The million-cell fixture is parsed three times over by the suites here and takes about a
    /// second each in an unoptimised build. Its byte-identity and fragment behaviour is the same
    /// as every other fixture's — what is unique about it is its *size*, and that is
    /// `ReadPerformanceTests`' subject, not this one's.
    static var workbooksExcludingTheHugeOne: [String] {
        workbooks.filter { $0 != "perf/1m-cells.xlsx" }
    }

    @Test("parses into a Workbook matching its .expected.json", arguments: workbooks)
    func matchesSidecar(path: String) async throws {
        let expected = try FixtureLibrary.expected(for: path)
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url(path))
        // Not `.strict`: `requiresExhaustiveCells` would fail every fixture whose sidecar carries
        // a *sample* of cells rather than all of them, which is deliberate for the big ones.
        let result = WorkbookMatcher.compare(workbook, to: expected)
        let (waived, real) = KnownModelDeviation.split(result.mismatches)
        #expect(
            real.isEmpty,
            Comment(rawValue: """
            \(path) did not match.
            \(MatchResult(mismatches: real, checked: result.checked).report())
              this fixture exists to prove: \(expected.proves)
            """)
        )
        for mismatch in waived {
            print("  [waived: \(KnownModelDeviation.reason(for: mismatch) ?? "")] \(path): \(mismatch)")
        }
    }

    /// Differences that come from the frozen model rather than from this reader.
    ///
    /// Logged in `docs/agents/MODEL-CHANGE-REQUESTS.md`. Kept as an explicit, named list rather
    /// than by loosening ``MatchOptions``, so a waiver stays visible and cannot quietly grow to
    /// cover a real bug: turning `checksNumberFormats` off for `formats/builtin-numfmts.xlsx`
    /// would disable the only thing that fixture exists to check.
    enum KnownModelDeviation {
        /// `NumberFormat.builtInCode(id:)` spells built-ins 39 and 40 with the trailing space that
        /// ECMA-376 §18.8.30 gives only to 37 and 38. `SheetModel` is frozen, the `numFmtId`
        /// round-trips either way, and the difference is one space in the positive section of an
        /// accounting format — so it is recorded rather than worked around, because the obvious
        /// workaround (seeding `customNumberFormats[39]`) would hand the writer a custom format
        /// with a reserved id, which is illegal in the file.
        static let accountingFormatSpacing = "SheetModel.NumberFormat.builtInCode(id:) 39/40 spacing"

        static func reason(for mismatch: Mismatch) -> String? {
            guard mismatch.kind == .numberFormat else { return nil }
            guard mismatch.expected.replacingOccurrences(of: " ", with: "")
                == mismatch.actual.replacingOccurrences(of: " ", with: "") else { return nil }
            return accountingFormatSpacing
        }

        static func split(_ mismatches: [Mismatch]) -> (waived: [Mismatch], real: [Mismatch]) {
            var waived: [Mismatch] = []
            var real: [Mismatch] = []
            for mismatch in mismatches {
                if reason(for: mismatch) != nil { waived.append(mismatch) } else { real.append(mismatch) }
            }
            return (waived, real)
        }
    }

    /// `OpaqueParts` holds **every** entry of the original archive, byte-identical.
    ///
    /// This is the contract A2's surgical writer stands on, so it is asserted per entry against
    /// the sidecar's own SHA-256 and CRC-32 rather than against anything this reader computed.
    @Test("keeps every archive entry byte-identical", arguments: workbooksExcludingTheHugeOne)
    func preservesEveryEntry(path: String) async throws {
        let expected = try FixtureLibrary.expected(for: path)
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url(path))
        let archive = try ZipReader.read(try FixtureLibrary.data(path), name: path)

        #expect(
            workbook.passthrough.entries.count == archive.entries.count,
            "\(path): passthrough holds \(workbook.passthrough.entries.count) of \(archive.entries.count) entries"
        )
        for entry in archive.entries {
            let kept = workbook.passthrough[entry.path]
            #expect(kept != nil, "\(path): '\(entry.path)' is missing from OpaqueParts")
            guard let kept else { continue }
            #expect(kept.compressedData == entry.compressedData, "\(path): '\(entry.path)' bytes differ")
            #expect(kept.crc32 == entry.crc32, "\(path): '\(entry.path)' crc32 differs")
            #expect(kept.compressionMethod == entry.compressionMethod, "\(path): '\(entry.path)' method differs")
            #expect(kept.extraFieldLocal == entry.extraFieldLocal, "\(path): '\(entry.path)' local extra differs")
            #expect(kept.extraFieldCentral == entry.extraFieldCentral, "\(path): '\(entry.path)' central extra differs")
        }

        // The sidecars in `passthrough/` carry independently-computed digests. Checking against
        // those means a bug in this reader cannot agree with itself into a green test.
        for (entryPath, digest) in expected.zipEntries ?? [:] {
            guard let entry = workbook.passthrough[entryPath] else {
                Issue.record("\(path): sidecar lists '\(entryPath)' but OpaqueParts does not hold it")
                continue
            }
            #expect(entry.crc32 == digest.crc32, "\(path): '\(entryPath)' crc32")
            let inflated = try archive.bytes(of: entry)
            #expect(inflated.count == digest.uncompressedSize, "\(path): '\(entryPath)' size")
            #expect(SHA256Digest.hex(inflated) == digest.sha256, "\(path): '\(entryPath)' sha256")
        }

        // Only the parts the model can regenerate may be declared modelled; everything else is
        // untouchable and the writer must copy it through.
        for entryPath in expected.passthroughEntries ?? [] {
            #expect(
                !workbook.passthrough.modelled.contains(entryPath),
                "\(path): '\(entryPath)' must never be marked modelled — A2 would regenerate it"
            )
        }
    }

    /// Every element the sidecar names must come back verbatim in `sheetLevelFragments`.
    ///
    /// `WAVE-1-ADDENDUM.md` §1 asks for this assertion by name. Dropping the one-line
    /// `<drawing r:id="rId1"/>` orphans a chart whose own part survived perfectly, and Excel then
    /// calls the workbook damaged.
    @Test("captures unmodelled worksheet children verbatim", arguments: workbooksExcludingTheHugeOne)
    func capturesSheetLevelFragments(path: String) async throws {
        let expected = try FixtureLibrary.expected(for: path)
        guard let required = expected.sheetLevelElementsThatMustSurvive, !required.isEmpty else { return }
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url(path))
        let sheet = try #require(workbook.sheets.first)
        let captured = sheet.sheetLevelFragments

        let sourcePart = try #require(sheet.partPath)
        let archive = try ZipReader.read(try FixtureLibrary.data(path), name: path)
        let original = String(decoding: try archive.bytes(of: sourcePart), as: UTF8.self)

        for element in required {
            if WorksheetReader.modelledWorksheetChildren.contains(element) {
                // Modelled elements are re-emitted from the model, not spliced, so capturing them
                // too would make the writer emit each of them twice.
                #expect(
                    captured.first(named: element) == nil,
                    "\(path): <\(element)> is modelled and must not also be captured"
                )
                continue
            }
            let fragment = captured.first(named: element)
            #expect(fragment != nil, "\(path): <\(element)> was not captured")
            guard let fragment else { continue }
            #expect(
                original.contains(fragment.xml),
                "\(path): the captured <\(element)> is not a verbatim substring of \(sourcePart)"
            )
        }

        // Schema order has to be recoverable, or the writer emits a sequence Excel silently
        // repairs by discarding what it did not expect.
        let ordered = captured.inSchemaOrder
        #expect(
            ordered.map(\.schemaOrder) == ordered.map(\.schemaOrder).sorted(),
            "\(path): fragments do not sort into schema order"
        )
        for fragment in captured {
            #expect(fragment.xml.hasPrefix("<"), "\(path): <\(fragment.elementName)> is not raw XML")
            #expect(fragment.xml.hasSuffix(">"), "\(path): <\(fragment.elementName)> is truncated")
        }
    }

    /// `<legacyDrawing>` survives, at the right ordinal, in both fixtures that have one.
    ///
    /// Called out separately from the corpus-wide fragment test because it is the element the
    /// capture list was missing: it is the pointer from a sheet to the VML that positions its cell
    /// comments, so dropping it leaves `xl/comments1.xml` byte-perfect and orphaned.
    @Test(
        "the pointer that keeps comments attached to their sheet survives",
        arguments: ["passthrough/comments.xlsx", "passthrough/kitchen-sink.xlsm"]
    )
    func legacyDrawingSurvives(path: String) async throws {
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url(path))
        let sheet = try #require(workbook.sheets.first)
        let fragment = try #require(
            sheet.sheetLevelFragments.first(named: "legacyDrawing"),
            "\(path): <legacyDrawing> was not captured"
        )
        #expect(fragment.xml.contains("r:id"), "\(path): the relationship id is what makes it useful")

        // It has to land between `drawing` and `drawingHF` in `CT_Worksheet`'s sequence. Sorted
        // past `tableParts` — where an unknown element goes — Excel "repairs" the file by
        // discarding it.
        #expect(fragment.schemaOrder > SheetFragment.schemaOrder(for: "drawing"))
        #expect(fragment.schemaOrder < SheetFragment.schemaOrder(for: "picture"))
        #expect(fragment.schemaOrder < SheetFragment.schemaOrder(for: "tableParts"))

        let ordered = sheet.sheetLevelFragments.inSchemaOrder.map(\.elementName)
        if let drawing = ordered.firstIndex(of: "drawing"), let legacy = ordered.firstIndex(of: "legacyDrawing") {
            #expect(drawing < legacy, "\(path): <drawing> must precede <legacyDrawing>")
        }
        if let tables = ordered.firstIndex(of: "tableParts"), let legacy = ordered.firstIndex(of: "legacyDrawing") {
            #expect(legacy < tables, "\(path): <legacyDrawing> must precede <tableParts>")
        }
    }

    /// Anything not modelled is captured — including an element nobody has a name for.
    ///
    /// The capture rule is "every direct child of `<worksheet>` that is not modelled", not "every
    /// element on a list". A list is always one schema revision behind, which is exactly how
    /// `legacyDrawing` came to be missing from `SheetFragment.capturedElements`.
    @Test("an element the schema has never heard of is still captured")
    func capturesUnknownElements() throws {
        let source = """
        <worksheet xmlns="urn:x"><dimension ref="A1:A1"/><sheetData><row r="1">\
        <c r="A1"><v>1</v></c></row></sheetData>\
        <acme:auditTrail xmlns:acme="urn:acme" signedBy="nobody"><acme:entry/></acme:auditTrail>\
        <legacyDrawing r:id="rId9"/></worksheet>
        """
        let sheet = try WorksheetReader.read(
            Array(source.utf8),
            part: "xl/worksheets/sheet1.xml",
            entry: WorkbookSheetEntry(name: "S", id: SheetID(1), relationshipID: "rId1", visibility: .visible),
            context: WorksheetReader.Context()
        )
        let captured: [SheetFragment] = sheet.sheetLevelFragments
        #expect(captured.map(\SheetFragment.elementName) == ["auditTrail", "legacyDrawing"])
        #expect(captured[0].xml.contains("acme:auditTrail"), "the original prefix has to survive")
        #expect(captured[0].xml.contains("signedBy=\"nobody\""))
        #expect(!SheetFragment.capturedElements.contains("auditTrail"), "the point is that no list names it")
    }

    // MARK: - Individual guarantees the matcher does not cover

    @Test("the 1904 fixture yields the same wall-clock dates as its 1900 twin")
    func epochsAgree() async throws {
        let nineteenHundred = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formats/dates-1900.xlsx")
        )
        let nineteenOhFour = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formats/dates-1904.xlsx")
        )
        #expect(nineteenHundred.meta.dateSystem == .excel1900)
        #expect(nineteenOhFour.meta.dateSystem == .excel1904)

        let left = try #require(nineteenHundred.sheets.first)
        let right = try #require(nineteenOhFour.sheets.first)
        var compared = 0
        var skipped: [String] = []
        left.cells.forEachCell(in: .entireSheet) { ref, cell in
            guard let serial = cell.value.number, let other = right.cells[ref]?.value.number else { return }
            // Column A of both files spells the wall-clock date out, which is the real contract:
            // "the two files must render identically".
            guard let label = left.cells[CellRef(row: ref.row, column: 0)]?.value.text else { return }

            if serial < 60 {
                // KNOWN CORPUS BUG, reported to A7. `dates-1904.xlsx` was generated with a flat
                // −1462 shift, but that offset only holds past the phantom leap day: the 1900
                // system counts a 1900-02-29 that never existed, so serials below 60 are 1461
                // apart, not 1462. Row 1 (1900-01-01, serial 1) therefore reads back as
                // 1899-12-31 in the 1904 file. Our conversion is right — see
                // `phantomDayShiftsTheEpochOffset` below, which proves it independently — so this
                // row is recorded rather than asserted.
                skipped.append("\(ref) \(label): 1900 serial \(serial), 1904 serial \(other)")
                return
            }

            let viaNineteenHundred = SerialDate.components(serial: serial, system: .excel1900)
            let viaNineteenOhFour = SerialDate.components(serial: other, system: .excel1904)
            #expect(
                (viaNineteenHundred.year, viaNineteenHundred.month, viaNineteenHundred.day)
                    == (viaNineteenOhFour.year, viaNineteenOhFour.month, viaNineteenOhFour.day),
                "\(ref) disagrees across epochs"
            )
            #expect(
                String(
                    format: "%04d-%02d-%02d",
                    viaNineteenHundred.year, viaNineteenHundred.month, viaNineteenHundred.day
                ) == label,
                "\(ref): the 1900 file's serial does not decode to its own label"
            )
            compared += 1
        }
        #expect(compared > 0, "the twins share no numeric cells, so nothing was actually compared")
        if !skipped.isEmpty {
            print("  [dates] skipped, pending an A7 fixture fix: \(skipped.joined(separator: "; "))")
        }
    }

    /// The phantom leap day makes the gap between the two epochs 1,461 days, not 1,462, for
    /// anything before 1900-03-01.
    ///
    /// Proved against the conversion directly rather than against the corpus, because the corpus
    /// currently disagrees with itself on exactly this point.
    @Test("the phantom day changes the offset between the two epochs")
    func phantomDayShiftsTheEpochOffset() throws {
        // 1900-01-01: serial 1 in the 1900 system, and 1,460 days before 1904-01-01.
        #expect(SerialDate.serial(year: 1900, month: 1, day: 1, system: .excel1900) == 1)
        #expect(SerialDate.serial(year: 1900, month: 1, day: 1, system: .excel1904) == -1460)
        // 1900-03-01, the first day past the phantom: the familiar 1,462 gap.
        #expect(SerialDate.serial(year: 1900, month: 3, day: 1, system: .excel1900) == 61)
        #expect(SerialDate.serial(year: 1900, month: 3, day: 1, system: .excel1904) == -1401)
        #expect(SerialDate.serial(year: 2024, month: 3, day: 15, system: .excel1900) == 45_366)
        #expect(SerialDate.serial(year: 2024, month: 3, day: 15, system: .excel1904) == 43_904)
    }

    @Test("serial 60 is the phantom 1900-02-29")
    func lotusLeapYearBug() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formats/serial-60-lotus-bug.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        var sawPhantom = false
        sheet.cells.forEachCell(in: .entireSheet) { _, cell in
            guard let serial = cell.value.number, serial == 60 else { return }
            let parts = SerialDate.components(serial: serial, system: workbook.meta.dateSystem)
            #expect(parts.isPhantomLeapDay)
            #expect((parts.year, parts.month, parts.day) == (1900, 2, 29))
            sawPhantom = true
        }
        #expect(sawPhantom, "the fixture no longer contains serial 60")
    }

    @Test("shared formulas expand with their references translated")
    func sharedFormulasExpand() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formulas/shared-formulas.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        for row in 0 ..< 8 {
            let ref = CellRef(row: row, column: 1)
            let cell = try #require(sheet.cells[ref], "no cell at \(ref)")
            #expect(cell.formula == "A\(row + 1)*2", "\(ref): \(cell.formula ?? "nil")")
            if row > 0 {
                #expect(cell.flags.contains(.sharedFormulaExpansion), "\(ref): missing expansion flag")
            }
        }
    }

    @Test("array formulas keep their region and flag every cell they spill into")
    func arrayFormulas() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formulas/array-formulas.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        let anchor = try #require(CellRef(a1: "D1"))
        #expect(sheet.arrayFormulaRanges[anchor] == CellRange(a1: "D1:D3"))
        #expect(sheet.cells[anchor]?.formula == "A1:A3*B1:B3")
        for address in ["D1", "D2", "D3"] {
            let ref = try #require(CellRef(a1: address))
            #expect(sheet.cells[ref]?.flags.contains(.arrayFormula) == true, "\(address): missing array flag")
        }
        // The followers carry only a `<v>`; writing them back as constants breaks the array on
        // the next Excel open, so they must not acquire formula text of their own.
        #expect(sheet.cells[try #require(CellRef(a1: "D2"))]?.formula == nil)

        let single = try #require(CellRef(a1: "F1"))
        #expect(sheet.arrayFormulaRanges[single] == CellRange(a1: "F1"))
    }

    @Test("external references are flagged and never resolved")
    func externalLinks() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("formulas/external-link.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        for address in ["A1", "B1", "C1"] {
            let ref = try #require(CellRef(a1: address))
            let cell = try #require(sheet.cells[ref])
            #expect(cell.flags.contains(.externalLink), "\(address): missing externalLink flag")
            #expect(cell.formula?.contains("[1]") == true, "\(address): the reference was rewritten")
        }
    }

    @Test("rich text flattens without losing whitespace, and is flagged")
    func richText() async throws {
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/rich-text.xlsx"))
        let sheet = try #require(workbook.sheets.first)
        var sawRich = false
        sheet.cells.forEachCell(in: .entireSheet) { _, cell in
            if cell.flags.contains(.richText) { sawRich = true }
        }
        #expect(sawRich, "no cell was marked rich — the writer would re-emit plain text and lose the runs")
    }

    @Test("hidden and very-hidden sheets survive as themselves")
    func sheetVisibility() async throws {
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/hidden-sheets.xlsx"))
        #expect(workbook.sheets.map(\.visibility) == [.visible, .hidden, .veryHidden, .visible])
        #expect(workbook.visibleSheets.count == 2)
    }

    @Test("a wrong <dimension> does not become the used range")
    func dimensionIsOnlyAHint() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("structure/col-widths-row-heights.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.declaredDimension == CellRange(a1: "A1:K4"), "the claim must still round-trip")
        #expect(sheet.usedRange == CellRange(a1: "A1:A4"), "but the computed range is what the cells say")
    }

    @Test("rows and cells out of order land where their references say")
    func outOfOrderRows() async throws {
        let workbook = try await XLSXReader.read(
            contentsOf: try FixtureLibrary.url("structure/out-of-order-rows.xlsx")
        )
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.declaredDimension == nil, "this fixture has no <dimension> at all")
        #expect(sheet.cells[try #require(CellRef(a1: "A1"))]?.value == .number(11))
        #expect(sheet.cells[try #require(CellRef(a1: "E9"))]?.value == .number(95))
        #expect(sheet.usedRange == CellRange(a1: "A1:E9"))
    }

    @Test("a merge extends the content extent past the cells that exist")
    func mergesExtendTheUsedRange() async throws {
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/merged-cells.xlsx"))
        let sheet = try #require(workbook.sheets.first)
        #expect(sheet.cells.count == 4)
        #expect(sheet.usedRange == CellRange(a1: "A1:F5"), "cells only")
        #expect(WorksheetReader.contentExtent(of: sheet) == CellRange(a1: "A1:F8"), "cells ∪ merges")
        #expect(WorksheetReader.contentExtent(of: sheet) == WorkbookMatcher.mergeAwareUsedRange(sheet))
    }

    @Test("a split is not a freeze")
    func splitPanesAreNotFrozen() async throws {
        let split = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/split-panes.xlsx"))
        let sheet = try #require(split.sheets.first)
        #expect(sheet.frozen.frozenRows == 0)
        #expect(sheet.frozen.frozenColumns == 0)
        #expect(sheet.frozen.isSplit)
        // 2130 twentieths of a point = 106.5 pt = 142 px at Excel's assumed 96 dpi.
        #expect(sheet.frozen.verticalSplit == 142)
        #expect(sheet.frozen.horizontalSplit == 60)

        let frozen = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/frozen-panes.xlsx"))
        let frozenSheet = try #require(frozen.sheets.first)
        #expect(frozenSheet.frozen.frozenColumns == 2)
        #expect(frozenSheet.frozen.frozenRows == 1)
        #expect(!frozenSheet.frozen.isSplit)
    }

    @Test("a 32,763-character cell is accepted")
    func longCellIsAccepted() async throws {
        let workbook = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("structure/long-cell-32k.xlsx"))
        let sheet = try #require(workbook.sheets.first)
        var longest = 0
        sheet.cells.forEachCell(in: .entireSheet) { _, cell in
            longest = max(longest, cell.value.text?.count ?? 0)
        }
        #expect(longest > 32_000 && longest <= Limits.maxCellTextLength)
    }

    /// A main document part we do not recognise opens read-only rather than opening writable.
    ///
    /// PLAN.md §5.2: refusing to save is always better than corrupting. The encrypted and `.xlsb`
    /// cases throw outright; this is the third one, where there is something to show but nothing
    /// safe to write.
    @Test("an unrecognised main part sets a read-only reason")
    func unknownCriticalPartOpensReadOnly() async throws {
        let original = try FixtureLibrary.data("basic/minimal.xlsx")
        let (clean, _) = try await XLSXReader.read(original, name: "clean")
        #expect(clean.meta.readOnlyReason == nil)
        #expect(clean.meta.isWritable)

        // The same archive with one content type rewritten to a foreign format family.
        let rewritten = try RepackagedArchive.replacing(
            "[Content_Types].xml",
            in: original,
            with: { part in
                part.replacingOccurrences(
                    of: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                    with: "application/vnd.oasis.opendocument.spreadsheet"
                )
            }
        )
        let (workbook, _) = try await XLSXReader.read(rewritten, name: "foreign")
        #expect(workbook.sheets.count == 1, "what can be read is still read")
        #expect(workbook.meta.readOnlyReason == .unknownCriticalPart)
        #expect(!workbook.meta.isWritable)
    }

    @Test("workbook-level facts come off workbook.xml, not off guesses")
    func workbookMetadata() async throws {
        let macros = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("passthrough/macros.xlsm"))
        #expect(macros.meta.containsMacros, "vbaProject.bin is present and must be announced")
        #expect(macros.meta.sourceFormat == .xlsm)
        #expect(macros.meta.isWritable, "a macro workbook is writable; the macros just pass through")

        let names = try await XLSXReader.read(contentsOf: try FixtureLibrary.url("formulas/defined-names.xlsx"))
        #expect(names.definedName("Revenue") != nil)
        #expect(names.definedName("GrowthRate")?.target?.range == CellRange(a1: "C1:C1"))
    }
}

/// A dependency-free SHA-256, so the per-entry digests in the sidecars can be checked without
/// pulling CryptoKit into a package that otherwise has one external dependency.
enum SHA256Digest {
    static func hex(_ message: [UInt8]) -> String {
        hash(message).map { String(format: "%08x", $0) }.joined()
    }

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    private static func hash(_ message: [UInt8]) -> [UInt32] {
        var state: [UInt32] = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
            0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
        ]
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bitCount = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0 ..< 16 {
                let base = chunk + index * 4
                schedule[index] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16
                    | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for index in 16 ..< 64 {
                let s0 = rotate(schedule[index - 15], 7) ^ rotate(schedule[index - 15], 18) ^ (schedule[index - 15] >> 3)
                let s1 = rotate(schedule[index - 2], 17) ^ rotate(schedule[index - 2], 19) ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }
            var working = state
            for index in 0 ..< 64 {
                let s1 = rotate(working[4], 6) ^ rotate(working[4], 11) ^ rotate(working[4], 25)
                let choose = (working[4] & working[5]) ^ (~working[4] & working[6])
                let temp1 = working[7] &+ s1 &+ choose &+ roundConstants[index] &+ schedule[index]
                let s0 = rotate(working[0], 2) ^ rotate(working[0], 13) ^ rotate(working[0], 22)
                let majority = (working[0] & working[1]) ^ (working[0] & working[2]) ^ (working[1] & working[2])
                let temp2 = s0 &+ majority
                working = [
                    temp1 &+ temp2, working[0], working[1], working[2],
                    working[3] &+ temp1, working[4], working[5], working[6],
                ]
            }
            for index in state.indices { state[index] = state[index] &+ working[index] }
        }
        return state
    }

    private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
