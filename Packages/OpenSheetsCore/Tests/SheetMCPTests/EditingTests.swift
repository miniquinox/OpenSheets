import Foundation
import SheetFormat
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// The writing tools: what they change, what they refuse, and what `preview: true` promises.
@Suite struct EditingTests {
    // MARK: - write_range

    /// Values and formulas land, dependents recalculate, and the file on disk holds the result.
    ///
    /// Reads the file back rather than the in-memory workbook: the whole point of this server is
    /// that the *file* changes, and an assertion on the session's copy would pass even if the
    /// save never happened.
    @Test @MainActor func writeRangeWritesValuesAndFormulas() async throws {
        let harness = try Harness.make("write-range")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("B2:C3"),
            "values": .array([.array([.integer(500), .integer(510)]), .array([.integer(600), .integer(610)])]),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("wrote 4 cells"))
        #expect(output.text.contains("saved"))

        let saved = try await harness.reload(path)
        let sheet = try #require(saved.sheets.first)
        #expect(sheet.cells[try cellRef("B2")]?.value == .number(500))
        #expect(sheet.cells[try cellRef("C3")]?.value == .number(610))
        // `D2` is `SUM(B2:C2)`, so the recalculation should have moved it to 1010.
        #expect(sheet.cells[try cellRef("D2")]?.value == .number(1010))
    }

    /// A formula is stored as a formula, with the `=` stripped the way OOXML wants it.
    @Test @MainActor func aLeadingEqualsMeansAFormula() async throws {
        let harness = try Harness.make("write-formula")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("E2"),
            "values": .array([.array([.string("=B2*2")])]),
        ])
        #expect(!output.isError, "\(output.text)")

        let saved = try await harness.reload(path)
        let cell = try #require(saved.sheets.first?.cells[try cellRef("E2")])
        #expect(cell.formula == "B2*2")
        #expect(cell.value == .number(200), "100 × 2, computed on the way in")
    }

    /// An apostrophe writes a literal that begins with `=`.
    @Test @MainActor func anApostropheEscapesALeadingEquals() async throws {
        let harness = try Harness.make("write-literal")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        _ = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("E2"),
            "values": .array([.array([.string("'=NOT A FORMULA")])]),
        ])
        let saved = try await harness.reload(path)
        let cell = try #require(saved.sheets.first?.cells[try cellRef("E2")])
        #expect(cell.formula == nil)
        #expect(cell.value == .text("=NOT A FORMULA"))
    }

    /// An unparseable formula fails the whole call and leaves the file untouched.
    ///
    /// Half-applied is the worst outcome: the agent's model of the sheet and the sheet itself
    /// disagree, and nothing tells it which cells landed.
    @Test @MainActor func abadFormulaWritesNothingAtAll() async throws {
        let harness = try Harness.make("write-bad-formula")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let before = try await harness.reload(path)

        let output = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("E2:E3"),
            "values": .array([.array([.integer(1)]), .array([.string("=SUM(")])]),
        ])
        #expect(output.isError)
        #expect(output.text.contains("formula.invalid"))

        let after = try await harness.reload(path)
        #expect(after.sheets[0].cells.count == before.sheets[0].cells.count)
        #expect(after.sheets[0].cells[try cellRef("E2")] == nil, "the first cell rolled back too")
    }

    /// A block that does not fit the named rectangle is refused with the two shapes named.
    @Test @MainActor func aShapeMismatchIsRefused() async throws {
        let harness = try Harness.make("write-shape")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("B2:C3"),
            "values": .array([.array([.integer(1), .integer(2)])]),
        ])
        #expect(output.isError)
        #expect(output.text.contains("range.shapeMismatch"))
    }

    /// `preview: true` reports the change and writes nothing.
    @Test @MainActor func previewWritesNothing() async throws {
        let harness = try Harness.make("write-preview")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: path))

        let output = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("B2"),
            "values": .array([.array([.integer(999)])]),
            "preview": .bool(true),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("would write"))
        #expect(output.text.contains("preview only, nothing written"))
        #expect(output.text.contains("100 → 999"), "\(output.text)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytesBefore, "the file changed during a preview")
    }

    /// Writing the same value again is a no-op, not a save.
    ///
    /// A save that produces identical bytes still takes a snapshot, bumps the mtime and makes
    /// the app refresh. An agent that re-runs its own edit should not cost the user any of that.
    @Test @MainActor func writingTheSameValueDoesNotTouchTheFile() async throws {
        let harness = try Harness.make("write-noop")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        _ = await harness.call("write_range", [
            "path": .string(path), "range": .string("B2"), "values": .array([.array([.integer(42)])]),
        ])
        let fingerprint = try FileFingerprint.capture(at: URL(fileURLWithPath: path))

        let again = await harness.call("write_range", [
            "path": .string(path), "range": .string("B2"), "values": .array([.array([.integer(42)])]),
        ])
        #expect(!again.isError, "\(again.text)")
        #expect(try FileFingerprint.capture(at: URL(fileURLWithPath: path)) == fingerprint)
    }

    // MARK: - Structural edits

    /// **Inserting a row rewrites the formulas that pointed past it.**
    ///
    /// This is the difference between a structural edit and a text substitution. `SUM(B2:B5)`
    /// after inserting a row at 3 has to become `SUM(B2:B6)`, or the total silently stops
    /// including a row that is now inside the range the user thinks it covers.
    @Test @MainActor func insertingRowsAdjustsFormulas() async throws {
        let harness = try Harness.make("insert-rows")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await harness.call("insert_rows", [
            "path": .string(path), "at": .integer(3), "count": .integer(2),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("adjusted"))

        let saved = try await harness.reload(path)
        let sheet = try #require(saved.sheets.first)
        // The totals row moved from 6 to 8, and its range grew with the insert.
        let total = try #require(sheet.cells[try cellRef("B8")])
        #expect(total.formula == "SUM(B2:B7)", "got \(total.formula ?? "nil")")
        // A row-level formula that moved down keeps pointing at its own row.
        let moved = try #require(sheet.cells[try cellRef("D5")])
        #expect(moved.formula == "SUM(B5:C5)", "got \(moved.formula ?? "nil")")
    }

    /// Deleting the rows a formula pointed at produces `#REF!`, not a quietly wrong answer.
    @Test @MainActor func deletingRowsInvalidatesWhatPointedAtThem() async throws {
        let harness = try Harness.make("delete-rows")
        var workbook = try Fixtures.budget()
        try workbook.sheets[0].cells.setCell(
            Cell(value: .number(0), formula: "B3"), at: try cellRef("F1")
        )
        let path = try harness.install(workbook, as: "budget.xlsx")

        let output = await harness.call("delete_rows", [
            "path": .string(path), "at": .integer(3), "count": .integer(1),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("#REF!"), "\(output.text)")

        let saved = try await harness.reload(path)
        let broken = try #require(saved.sheets[0].cells[try cellRef("F1")])
        #expect(broken.formula?.contains("#REF!") == true, "got \(broken.formula ?? "nil")")
    }

    /// A column insert moves the data and the formulas that follow it.
    @Test @MainActor func insertingColumnsAdjustsFormulas() async throws {
        let harness = try Harness.make("insert-columns")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await harness.call("insert_columns", [
            "path": .string(path), "column": .string("B"), "count": .integer(1),
        ])
        #expect(!output.isError, "\(output.text)")

        let saved = try await harness.reload(path)
        let sheet = try #require(saved.sheets.first)
        #expect(sheet.cells[try cellRef("C2")]?.value == .number(100), "Q1 moved from B to C")
        let total = try #require(sheet.cells[try cellRef("E2")])
        #expect(total.formula == "SUM(C2:D2)", "got \(total.formula ?? "nil")")
    }

    /// Formulas on *other* sheets are adjusted too.
    ///
    /// The easy version of this pass only walks the sheet that changed, and a cross-sheet
    /// reference is exactly the case nobody notices until a quarterly report is wrong.
    @Test @MainActor func crossSheetFormulasAreAdjusted() async throws {
        let harness = try Harness.make("cross-sheet")
        let path = try harness.install(try Fixtures.multiSheet(), as: "multi.xlsx")

        let output = await harness.call("insert_rows", [
            "path": .string(path), "sheet": .string("Data"), "at": .integer(2), "count": .integer(3),
        ])
        #expect(!output.isError, "\(output.text)")

        let saved = try await harness.reload(path)
        let summary = try #require(saved.sheet(named: "Summary"))
        let formula = try #require(summary.cells[try cellRef("B2")]?.formula)
        #expect(formula.contains("C5:C103"), "the Summary total should follow the insert; got \(formula)")
    }

    /// `preview: true` on a delete reports the shape of the damage without doing it.
    @Test @MainActor func structuralPreviewChangesNothing() async throws {
        let harness = try Harness.make("structural-preview")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let output = await harness.call("delete_rows", [
            "path": .string(path), "at": .integer(2), "count": .integer(2), "preview": .bool(true),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("would delete"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    /// A row number of zero is a caller mistake, and 1-based indexing is said out loud.
    @Test @MainActor func rowNumbersAreOneBased() async throws {
        let harness = try Harness.make("one-based")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("insert_rows", ["path": .string(path), "at": .integer(0)])
        #expect(output.isError)
        #expect(output.text.contains("1-based"))
    }

    // MARK: - set_format

    /// Formatting one cell does not restyle every cell that shared its style.
    ///
    /// The naive implementation mutates the style in place, and because a fresh workbook has
    /// every cell on style 0, the result is a workbook where one bold request bolded everything.
    @Test @MainActor func formattingOneCellLeavesItsNeighboursAlone() async throws {
        let harness = try Harness.make("format-interning")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1:D1"), "bold": .bool(true),
        ])
        #expect(!output.isError, "\(output.text)")

        let saved = try await harness.reload(path)
        let sheet = try #require(saved.sheets.first)
        let header = try #require(sheet.cells[try cellRef("A1")])
        let body = try #require(sheet.cells[try cellRef("A2")])
        #expect(saved.styles[header.styleID].font.isBold)
        #expect(!saved.styles[body.styleID].font.isBold, "a body cell was restyled by a header edit")
    }

    /// A number format is applied, and the value underneath is untouched.
    @Test @MainActor func numberFormatsApplyWithoutChangingValues() async throws {
        let harness = try Harness.make("format-number")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        _ = await harness.call("set_format", [
            "path": .string(path), "range": .string("B2:C5"), "numberFormat": .string("#,##0.00"),
        ])
        let saved = try await harness.reload(path)
        let cell = try #require(saved.sheets[0].cells[try cellRef("B2")])
        #expect(cell.value == .number(100))
        #expect(saved.styles.numberFormat(for: cell.styleID).formatCode == "#,##0.00")
    }

    /// An invalid colour names the field and the format it wanted.
    @Test @MainActor func aBadColourIsRejected() async throws {
        let harness = try Harness.make("format-colour")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1"), "fillColor": .string("chartreuse"),
        ])
        #expect(output.isError)
        #expect(output.text.contains("fillColor"))
        #expect(output.text.contains("RRGGBB"))
    }

    /// With no formatting fields at all, the tool says so rather than saving nothing.
    @Test @MainActor func formattingNothingIsAnError() async throws {
        let harness = try Harness.make("format-empty")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("set_format", ["path": .string(path), "range": .string("A1")])
        #expect(output.isError)
        #expect(output.text.contains("nothing to do"))
    }

    // MARK: - sort and filter

    /// Sorting reorders the rows and keeps the header where it is.
    @Test @MainActor func sortReordersRowsBelowTheHeader() async throws {
        let harness = try Harness.make("sort")
        var workbook = Workbook(sheets: [Sheet(id: SheetID(1), name: "Data")])
        try workbook.sheets[0].cells.setCell(.text("name"), at: CellRef(row: 0, column: 0))
        try workbook.sheets[0].cells.setCell(.text("score"), at: CellRef(row: 0, column: 1))
        for (offset, pair) in [("Charlie", 30.0), ("Alice", 10.0), ("Bob", 20.0)].enumerated() {
            try workbook.sheets[0].cells.setCell(.text(pair.0), at: CellRef(row: offset + 1, column: 0))
            try workbook.sheets[0].cells.setCell(.number(pair.1), at: CellRef(row: offset + 1, column: 1))
        }
        let path = try harness.install(workbook, as: "sort.xlsx")

        let output = await harness.call("sort", [
            "path": .string(path),
            "by": .array([.object(["column": .string("B"), "order": .string("asc")])]),
        ])
        #expect(!output.isError, "\(output.text)")

        let saved = try await harness.reload(path)
        let sheet = try #require(saved.sheets.first)
        #expect(sheet.cells[CellRef(row: 0, column: 0)]?.value == .text("name"), "the header stayed put")
        #expect(sheet.cells[CellRef(row: 1, column: 0)]?.value == .text("Alice"))
        #expect(sheet.cells[CellRef(row: 3, column: 0)]?.value == .text("Charlie"))
    }

    /// A range holding formulas is refused unless the caller says otherwise.
    @Test @MainActor func sortRefusesFormulasUnlessAsked() async throws {
        let harness = try Harness.make("sort-formulas")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("sort", [
            "path": .string(path),
            "range": .string("A1:D5"),
            "by": .array([.object(["column": .string("B"), "order": .string("desc")])]),
        ])
        #expect(output.isError)
        #expect(output.text.contains("allowFormulas"))
    }

    /// `filter` answers "which rows" without returning the data.
    @Test @MainActor func filterReturnsRowNumbers() async throws {
        let harness = try Harness.make("filter")
        let path = try harness.install(try Fixtures.salesLedger(rows: 300), as: "sales.xlsx")

        let output = await harness.call("filter", [
            "path": .string(path),
            "where": .array([.object([
                "column": .string("Margin"), "op": .string("lt"), "value": .number(0),
            ])]),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("rows matched"))
        #expect(output.text.contains("rows: "), "\(output.text)")
    }

    /// A comparison that does not apply to a cell's type is counted, not silently false.
    ///
    /// Excel's answer — text sorts above every number — makes `< 0` match a cell reading `n/a`,
    /// which is a trap for anyone filtering for "everything below zero". Saying how many cells
    /// were skipped turns a wrong answer into a question the agent can ask.
    @Test @MainActor func filterReportsTypeMismatchesRatherThanHidingThem() async throws {
        let harness = try Harness.make("filter-types")
        let path = try harness.install(try Fixtures.mixedTypes(), as: "imported.xlsx")

        let output = await harness.call("filter", [
            "path": .string(path),
            "where": .array([.object([
                "column": .string("amount"), "op": .string("gt"), "value": .number(5),
            ])]),
        ])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("skipped"), "\(output.text)")
    }

    /// `filter` can delete what it matched, in coalesced blocks, with a preview first.
    @Test @MainActor func filterCanDeleteTheRowsItMatched() async throws {
        let harness = try Harness.make("filter-delete")
        var workbook = Workbook(sheets: [Sheet(id: SheetID(1), name: "Rows")])
        try workbook.sheets[0].cells.setCell(.text("status"), at: CellRef(row: 0, column: 0))
        for row in 1 ... 10 {
            try workbook.sheets[0].cells.setCell(
                .text(row <= 4 ? "cancelled" : "open"), at: CellRef(row: row, column: 0)
            )
        }
        let path = try harness.install(workbook, as: "rows.xlsx")

        let preview = await harness.call("filter", [
            "path": .string(path),
            "action": .string("delete_rows"),
            "preview": .bool(true),
            "where": .array([.object([
                "column": .string("status"), "op": .string("eq"), "value": .string("cancelled"),
            ])]),
        ])
        #expect(preview.text.contains("would delete 4 rows"), "\(preview.text)")
        #expect(preview.text.contains("1 contiguous block"), "\(preview.text)")

        let output = await harness.call("filter", [
            "path": .string(path),
            "action": .string("delete_rows"),
            "where": .array([.object([
                "column": .string("status"), "op": .string("eq"), "value": .string("cancelled"),
            ])]),
        ])
        #expect(!output.isError, "\(output.text)")
        let saved = try await harness.reload(path)
        #expect(saved.sheets[0].cells.count == 7, "a header and six open rows")
        #expect(saved.sheets[0].cells[CellRef(row: 1, column: 0)]?.value == .text("open"))
    }

    // MARK: - Refusals

    /// Adding and deleting a sheet refuse, honestly, with something to do instead.
    @Test @MainActor func sheetStructureChangesRefuseWithAnAlternative() async throws {
        let harness = try Harness.make("sheet-refusals")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let add = await harness.call("add_sheet", ["path": .string(path), "name": .string("New")])
        #expect(add.isError)
        #expect(add.text.contains("not supported in v0.1"))
        #expect(add.text.contains("Excel"), "\(add.text)")

        let remove = await harness.call("delete_sheet", ["path": .string(path), "sheet": .string("Budget")])
        #expect(remove.isError)
        #expect(remove.text.contains("delete_rows"), "\(remove.text)")

        // And nothing happened to the file.
        let saved = try await harness.reload(path)
        #expect(saved.sheets.count == 1)
    }

    /// Renaming a sheet works, and the file says so.
    @Test @MainActor func renamingASheetWorks() async throws {
        let harness = try Harness.make("rename")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("rename_sheet", [
            "path": .string(path), "sheet": .string("Budget"), "name": .string("Plan 2027"),
        ])
        #expect(!output.isError, "\(output.text)")
        let saved = try await harness.reload(path)
        #expect(saved.sheets[0].name == "Plan 2027")
    }

    /// An illegal sheet name is refused by Excel's own rules.
    @Test @MainActor func illegalSheetNamesAreRefused() async throws {
        let harness = try Harness.make("rename-bad")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("rename_sheet", [
            "path": .string(path), "sheet": .string("Budget"), "name": .string("a/b:c"),
        ])
        #expect(output.isError)
        #expect(output.text.contains("sheet.invalidName"))
    }

    // MARK: - recalc

    /// A workbook whose cached values are wrong is corrected, and the tool says how many moved.
    @Test @MainActor func recalcFixesStaleCachedValues() async throws {
        let harness = try Harness.make("recalc")
        var workbook = try Fixtures.budget()
        // A cached value that disagrees with its own formula — what a foreign editor leaves.
        try workbook.sheets[0].cells.setCell(
            Cell(value: .number(-1), formula: "SUM(B2:C2)"), at: try cellRef("D2")
        )
        let path = try harness.install(workbook, as: "budget.xlsx")

        let output = await harness.call("recalc", ["path": .string(path)])
        #expect(!output.isError, "\(output.text)")
        #expect(output.text.contains("evaluated"))

        let saved = try await harness.reload(path)
        #expect(saved.sheets[0].cells[try cellRef("D2")]?.value == .number(210))
    }

    // MARK: - Region marking

    /// **A cell edit must not regenerate `<cols>` or `<sheetFormatPr>`.**
    ///
    /// Wave 2 addendum §2: our display default row height is 24 pt, and regenerating
    /// `<sheetFormatPr>` from the model writes 24 into a file that said 15 — making every row in
    /// the workbook 60% taller in Excel. The tracker a cell edit produces must therefore name
    /// `.cells` and nothing else.
    @Test @MainActor func aCellEditMarksOnlyCells() async throws {
        let harness = try Harness.make("regions")
        let path = try harness.install(
            try Fixtures.budget(partPath: "xl/worksheets/sheet1.xml"), as: "budget.xlsx"
        )
        let url = URL(fileURLWithPath: path)

        let outcome = try await harness.broker.edit(path: path, preview: true, tool: "test") { workbook, edits in
            try workbook.sheets[0].cells.setCell(.number(1), at: CellRef(row: 1, column: 1))
            edits.noteCellsChanged(in: workbook.sheets[0], formulasChanged: false)
            return edits.regions(for: workbook.sheets[0])
        }
        #expect(outcome.value == .cells)
        #expect(await harness.broker.pendingEdits(for: url) == nil, "a preview must not arm the writer")
    }

    /// A row insert marks rows, merges, hyperlinks and the filter range — and *not* columns.
    @Test @MainActor func aRowInsertMarksEverythingItMoves() async throws {
        // A sheet that came from a real package. Without a `partPath` the tracker answers
        // `.all` — correctly, because a sheet with no original part has nothing to copy through
        // — and the assertion below would be testing the wrong branch.
        var workbook = try Fixtures.budget(partPath: "xl/worksheets/sheet1.xml")
        workbook.sheets[0].merges = [try cellRange("A1:B1")]
        var edits = WorkbookEditTracker()
        _ = try StructuralEditor.apply(
            .insertRows(at: 2, count: 1, on: SheetID(1)), to: &workbook, edits: &edits
        )
        let regions = edits.regions(for: workbook.sheets[0])
        #expect(regions.contains(.cells))
        #expect(regions.contains(.rows))
        #expect(regions.contains(.merges))
        #expect(regions.contains(.hyperlinks))
        #expect(regions.contains(.autoFilter))
        #expect(!regions.contains(.columns), "a row insert must not regenerate <cols>")
    }

    /// A column insert marks columns rather than rows, for the same reason in the other axis.
    @Test @MainActor func aColumnInsertMarksColumns() async throws {
        var workbook = try Fixtures.budget(partPath: "xl/worksheets/sheet1.xml")
        var edits = WorkbookEditTracker()
        _ = try StructuralEditor.apply(
            .insertColumns(at: 1, count: 1, on: SheetID(1)), to: &workbook, edits: &edits
        )
        let regions = edits.regions(for: workbook.sheets[0])
        #expect(regions.contains(.columns))
        #expect(!regions.contains(.rows))
    }

    /// Bands coalesce, so a contiguous block of deletions is one structural edit.
    @Test func contiguousRowsCoalesceIntoOneBand() {
        let bands = StructuralEditor.bands(rows: [3, 4, 5, 9, 10, 20])
        #expect(bands == [
            StructuralEditor.Band(start: 3, count: 3),
            StructuralEditor.Band(start: 9, count: 2),
            StructuralEditor.Band(start: 20, count: 1),
        ])
        #expect(StructuralEditor.bands(rows: []).isEmpty)
        #expect(StructuralEditor.bands(rows: [7, 7, 7]).count == 1, "duplicates collapse")
    }

    // MARK: - Rate limiting

    /// A burst of writes is spaced out rather than turning into a burst of file replaces.
    ///
    /// The throttle makes the *call* wait rather than deferring the write, so a tool that
    /// returned always means the file is saved — an agent that writes and then reads with
    /// another tool never sees a stale file.
    @Test @MainActor func writesAreRateLimited() async throws {
        let harness = try Harness.make(
            "rate-limit",
            configuration: DocumentBroker.Configuration(minimumWriteInterval: .milliseconds(120))
        )
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let started = ContinuousClock.now
        for value in 1 ... 4 {
            let output = await harness.call("write_range", [
                "path": .string(path), "range": .string("B2"), "values": .array([.array([.integer(value)])]),
            ])
            #expect(!output.isError, "\(output.text)")
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .milliseconds(300), "four writes finished in \(elapsed); the throttle did not engage")

        // And the last one is what is on disk: throttling delays, it never drops.
        let saved = try await harness.reload(path)
        #expect(saved.sheets[0].cells[try cellRef("B2")]?.value == .number(4))
    }
}
