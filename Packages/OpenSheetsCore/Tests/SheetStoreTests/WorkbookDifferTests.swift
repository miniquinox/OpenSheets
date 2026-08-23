import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §6.4. The difference between a diff panel somebody uses and one they close.
@Suite struct WorkbookDifferTests {
    private let differ = WorkbookDiffer()

    // MARK: - The one that makes the panel usable

    /// **Inserting one row into a 10,000-row sheet reports a structural insert, not 10,000
    /// changes.**
    ///
    /// Without the row alignment every cell below the insert has moved, so a positional
    /// comparison reports 40,000 changed cells for a one-row edit. That panel is unreadable and
    /// the refresh pill's count is a lie.
    @Test func insertingOneRowIntoTenThousandIsOneStructuralChange() throws {
        var before = makeSheet(rows: 10_000, columns: 4)
        var after = before
        try after.insertRows(at: 5, count: 1)
        for column in 0 ..< 4 {
            try after.cells.setCell(Cell(value: .text("new-\(column)")), at: CellRef(row: 5, column: column))
        }
        before.name = "Data"
        after.name = "Data"

        let diff = differ.diff(before: before, after: after)
        #expect(diff.structuralChanges == [StructuralChange(kind: .insertedRows, index: 5, count: 1)])
        #expect(diff.structuralChanges.first?.summary == "inserted 1 row at 6")
        #expect(diff.addedCount == 4, "the inserted row's own four cells are the only additions")
        #expect(diff.changedCount == 0, "\(diff.changedCount) cells reported as changed by a row insert")
        #expect(diff.removedCount == 0)
        #expect(diff.totalCellChangeCount == 4)
    }

    /// The same, for a deletion.
    @Test func deletingRowsIsOneStructuralChange() throws {
        let before = makeSheet(rows: 5000, columns: 3)
        var after = before
        try after.deleteRows(at: 100, count: 3)

        let diff = differ.diff(before: before, after: after)
        #expect(diff.structuralChanges == [StructuralChange(kind: .deletedRows, index: 100, count: 3)])
        #expect(diff.removedCount == 9)
        #expect(diff.changedCount == 0)
    }

    /// Columns too, via a second alignment pass over per-column hashes.
    @Test func insertingAColumnIsOneStructuralChange() throws {
        let before = makeSheet(rows: 200, columns: 8)
        var after = before
        try after.insertColumns(at: 2, count: 1)

        let diff = differ.diff(before: before, after: after)
        #expect(diff.structuralChanges == [StructuralChange(kind: .insertedColumns, index: 2, count: 1)])
        #expect(diff.structuralChanges.first?.summary == "inserted 1 column at C")
        #expect(diff.changedCount == 0, "\(diff.changedCount) cells reported as changed by a column insert")
    }

    /// Two separate inserts are two runs, not one span covering the gap between them.
    @Test func separateInsertsAreSeparateRuns() throws {
        let before = makeSheet(rows: 400, columns: 2)
        var after = before
        try after.insertRows(at: 300, count: 2)
        try after.insertRows(at: 10, count: 1)
        try after.cells.setCell(Cell(value: .text("a")), at: CellRef(row: 10, column: 0))
        try after.cells.setCell(Cell(value: .text("b")), at: CellRef(row: 301, column: 0))
        try after.cells.setCell(Cell(value: .text("c")), at: CellRef(row: 302, column: 0))

        let diff = differ.diff(before: before, after: after)
        #expect(diff.structuralChanges.count == 2, "got \(diff.structuralChanges.map(\.summary))")
        #expect(diff.structuralChanges.contains(StructuralChange(kind: .insertedRows, index: 10, count: 1)))
        #expect(diff.structuralChanges.contains(StructuralChange(kind: .insertedRows, index: 301, count: 2)))
    }

    // MARK: - Ordinary cell changes

    /// Changed values are reported with before and after, classified by what actually differs.
    @Test func classifiesCellChanges() throws {
        var before = Sheet(id: 1, name: "S")
        try before.cells.setCell(Cell(value: .number(120)), at: CellRef(row: 1, column: 3))
        try before.cells.setCell(Cell(value: .text("keep")), at: CellRef(row: 2, column: 0))
        try before.cells.setCell(Cell(value: .text("gone")), at: CellRef(row: 3, column: 0))

        var after = before
        try after.cells.setCell(Cell(value: .number(129.6)), at: CellRef(row: 1, column: 3))
        _ = after.cells.removeCell(at: CellRef(row: 3, column: 0))
        try after.cells.setCell(Cell(value: .text("brand new")), at: CellRef(row: 4, column: 1))

        let diff = differ.diff(before: before, after: after)
        #expect(diff.changedCount == 1)
        #expect(diff.addedCount == 1)
        #expect(diff.removedCount == 1)

        let change = try #require(diff.cellChanges.first { $0.ref == CellRef(row: 1, column: 3) })
        #expect(change.kind == .valueChanged)
        #expect(change.before?.value == .number(120))
        #expect(change.after?.value == .number(129.6))
    }

    /// A formula change is reported as a formula change even though the cached value moved
    /// too — reporting it as a value change hides the interesting half.
    @Test func formulaChangesOutrankValueChanges() throws {
        var before = Sheet(id: 1, name: "S")
        try before.cells.setCell(
            Cell(value: .number(10), formula: "SUM(A1:A3)"),
            at: CellRef(row: 0, column: 5)
        )
        var after = before
        try after.cells.setCell(
            Cell(value: .number(20), formula: "SUM(A1:A6)"),
            at: CellRef(row: 0, column: 5)
        )

        let diff = differ.diff(before: before, after: after)
        #expect(diff.cellChanges.first?.kind == .formulaChanged)
    }

    /// A restyle is a change, and it is a *quiet* one — the grid must not flash for it. The row
    /// content hash deliberately excludes styles, so this only works if aligned rows are still
    /// compared cell by cell.
    @Test func styleOnlyChangesAreReportedSeparately() throws {
        var before = makeSheet(rows: 50, columns: 3)
        var after = before
        var cell = try #require(after.cells[CellRef(row: 10, column: 1)])
        cell.styleID = StyleID(7)
        try after.cells.setCell(cell, at: CellRef(row: 10, column: 1))
        before.name = "S"
        after.name = "S"

        let diff = differ.diff(before: before, after: after)
        #expect(diff.cellChanges.count == 1)
        #expect(diff.cellChanges.first?.kind == .styleChanged)

        let quiet = WorkbookDiffer(options: WorkbookDiffer.Options(includesStyleOnlyChanges: false))
        #expect(quiet.diff(before: before, after: after).isEmpty)
    }

    // MARK: - Bounds

    /// **The reported list is capped and the count is still accurate.** An unbounded array here
    /// turns a big external edit into a hang, and a count derived from the truncated array
    /// turns `+N more` into a guess.
    @Test func cellChangeListIsCappedWithAnAccurateRemainder() throws {
        let before = makeSheet(rows: 400, columns: 40)
        var after = before
        for row in 0 ..< 400 {
            for column in 0 ..< 40 {
                try after.cells.setCell(
                    Cell(value: .number(Double(row * 40 + column) + 0.5)),
                    at: CellRef(row: row, column: column)
                )
            }
        }

        let capped = WorkbookDiffer(options: WorkbookDiffer.Options(maximumListedChangesPerSheet: 100))
        let diff = capped.diff(before: before, after: after)
        #expect(diff.cellChanges.count == 100)
        #expect(diff.totalCellChangeCount == 16_000)
        #expect(diff.omittedCellChangeCount == 15_900)
        #expect(diff.cellChanges.count + diff.omittedCellChangeCount == diff.totalCellChangeCount)
    }

    /// **A 100,000-cell diff is linear in the number of cells.**
    ///
    /// Asserted by counting comparisons rather than by timing. Seven agents build on this
    /// machine at once (WAVE-1-ADDENDUM §8) and swift-testing runs suites in parallel, so the
    /// same diff measured twice a minute apart came back at 1.8 s and 7.4 s — wall-clock here
    /// reports the machine, not the algorithm. Comparisons report the algorithm: the diff that
    /// this one replaced, a positional walk with no row alignment, would do one comparison per
    /// cell *per shifted row*, and an O(n·m) LCS would do millions. This does about one per
    /// populated cell, and that number is the same on an idle machine and a hammered one.
    ///
    /// The wall-clock target from the brief — under 1 s for 100k cells — is met comfortably in
    /// release, which is the configuration `Scripts/test.sh --release` exists for.
    @Test func hundredThousandCellDiffIsLinear() throws {
        var before = Workbook(sheets: [makeSheet(rows: 2500, columns: 40)])
        var after = before
        try after.sheets[0].cells.setCell(Cell(value: .text("edited")), at: CellRef(row: 1200, column: 7))
        before.sheets[0].name = "Big"
        after.sheets[0].name = "Big"

        var statistics = WorkbookDiffer.Statistics()
        let diff = differ.diff(before: before, after: after, statistics: &statistics)

        #expect(diff.totalCellChangeCount == 1)
        #expect(diff.sheetDiffs.first?.cellChanges.first?.ref == CellRef(row: 1200, column: 7))
        #expect(
            statistics.cellComparisons <= 100_000 * 2,
            "\(statistics.cellComparisons) comparisons for 100,000 cells is not linear"
        )
        #expect(!statistics.columnDetectionRan, "one changed cell should not trigger a column-structure pass")
    }

    /// The 10,000-row insert, counted the same way: a structural insert costs one pass, not one
    /// pass per shifted row.
    @Test func structuralInsertDoesNotCostQuadraticWork() throws {
        var before = Workbook(sheets: [makeSheet(rows: 10_000, columns: 4)])
        var after = before
        try after.sheets[0].insertRows(at: 5, count: 1)
        try after.sheets[0].cells.setCell(Cell(value: .text("new")), at: CellRef(row: 5, column: 0))
        before.sheets[0].name = "Data"
        after.sheets[0].name = "Data"

        var statistics = WorkbookDiffer.Statistics()
        let diff = differ.diff(before: before, after: after, statistics: &statistics)

        #expect(diff.sheetDiffs.first?.structuralChanges.first?.kind == .insertedRows)
        #expect(
            statistics.cellComparisons <= 40_000 * 2,
            "\(statistics.cellComparisons) comparisons for a one-row insert into 40,000 cells"
        )
    }

    /// The alignment gives up rather than grinding when the two sheets are unrelated, and the
    /// diff is still correct — just without structural detection.
    @Test func unrelatedSheetsFallBackWithoutHanging() throws {
        let before = Workbook(sheets: [makeSheet(rows: 3000, columns: 2, seed: 0)])
        let after = Workbook(sheets: [makeSheet(rows: 3000, columns: 2, seed: 500_000)])

        var statistics = WorkbookDiffer.Statistics()
        let diff = differ.diff(before: before, after: after, statistics: &statistics)

        #expect(diff.totalCellChangeCount == 6000)
        // The edit-distance cap is what keeps the *alignment* bounded; the comparison itself
        // is still one pass over the cells even when the alignment gave up on them.
        #expect(
            statistics.cellComparisons <= 6000 * 3,
            "\(statistics.cellComparisons) comparisons for two unrelated 6,000-cell sheets"
        )
    }

    // MARK: - Sheets

    /// Matched on id first, so a rename is a rename rather than an add and a remove.
    @Test func matchesSheetsByIDThroughARename() throws {
        let before = Workbook(sheets: [makeSheet(id: 1, name: "Sheet1", rows: 10, columns: 2)])
        var after = before
        after.sheets[0].name = "Q4"

        let diff = differ.diff(before: before, after: after)
        #expect(diff.renamedSheets == [SheetRename(id: SheetID(1), before: "Sheet1", after: "Q4")])
        #expect(diff.addedSheets.isEmpty)
        #expect(diff.removedSheets.isEmpty)
        #expect(diff.summary.contains("1 renamed"))
    }

    /// Matched on name when a producer renumbered the ids — which openpyxl does.
    @Test func matchesSheetsByNameWhenIDsChange() throws {
        let before = Workbook(sheets: [makeSheet(id: 1, name: "Revenue", rows: 10, columns: 2)])
        var after = Workbook(sheets: [makeSheet(id: 99, name: "Revenue", rows: 10, columns: 2)])
        try after.sheets[0].cells.setCell(Cell(value: .text("x")), at: CellRef(row: 0, column: 0))

        let diff = differ.diff(before: before, after: after)
        #expect(diff.addedSheets.isEmpty)
        #expect(diff.removedSheets.isEmpty)
        #expect(diff.sheetDiffs.count == 1)
        #expect(diff.sheetDiffs.first?.changedCount == 1)
    }

    /// Matched on content when both the id and the name changed. Reporting "a sheet vanished
    /// and an unrelated one appeared" for a rename is exactly the unusable-panel failure.
    @Test func matchesSheetsByContentSimilarity() throws {
        let before = Workbook(sheets: [makeSheet(id: 1, name: "Sheet1", rows: 200, columns: 3)])
        var after = Workbook(sheets: [makeSheet(id: 42, name: "Q4 Revenue", rows: 200, columns: 3)])
        try after.sheets[0].cells.setCell(Cell(value: .text("edited")), at: CellRef(row: 3, column: 1))

        let diff = differ.diff(before: before, after: after)
        #expect(diff.addedSheets.isEmpty, "a renamed-and-renumbered sheet was reported as added")
        #expect(diff.removedSheets.isEmpty)
        #expect(diff.renamedSheets.first?.before == "Sheet1")
        #expect(diff.renamedSheets.first?.after == "Q4 Revenue")
        #expect(diff.renamedSheets.first?.id == SheetID(42), "the id reported must be the one that can be looked up")
    }

    /// Genuinely new and genuinely gone sheets are reported as such.
    @Test func reportsAddedAndRemovedSheets() {
        let before = Workbook(sheets: [makeSheet(id: 1, name: "A", rows: 5, columns: 2)])
        let after = Workbook(sheets: [
            makeSheet(id: 1, name: "A", rows: 5, columns: 2),
            makeSheet(id: 2, name: "B", rows: 3, columns: 2, seed: 9000),
        ])

        let forwards = differ.diff(before: before, after: after)
        #expect(forwards.addedSheets.map(\.name) == ["B"])
        #expect(forwards.addedSheets.first?.cellCount == 6)
        #expect(forwards.summary.contains("1 sheet added"))

        let backwards = differ.diff(before: after, after: before)
        #expect(backwards.removedSheets.map(\.name) == ["B"])
    }

    /// Two identical workbooks diff to nothing at all.
    @Test func identicalWorkbooksProduceAnEmptyDiff() {
        let workbook = Workbook(sheets: [makeSheet(rows: 100, columns: 5)])
        let diff = differ.diff(before: workbook, after: workbook)
        #expect(diff.isEmpty)
        #expect(diff.summary == "no changes")
        #expect(!diff.wasTruncated)
    }

    // MARK: - The alignment, on its own

    @Test func alignmentHandlesTheEdgeShapes() {
        #expect(LineAlignment.align(before: [], after: []).steps.isEmpty)

        let inserted = LineAlignment.align(before: [1, 2, 3], after: [1, 9, 2, 3])
        #expect(inserted.steps == [
            .matched(before: 0, after: 0),
            .inserted(after: 1),
            .matched(before: 1, after: 2),
            .matched(before: 2, after: 3),
        ])

        let deleted = LineAlignment.align(before: [1, 2, 3], after: [1, 3])
        #expect(deleted.steps == [
            .matched(before: 0, after: 0),
            .deleted(before: 1),
            .matched(before: 2, after: 1),
        ])

        let replaced = LineAlignment.align(before: [1, 2, 3], after: [1, 9, 3])
        #expect(replaced.matches[0] == 0)
        #expect(replaced.matches[2] == 2)

        let fromEmpty = LineAlignment.align(before: [], after: [1, 2])
        #expect(fromEmpty.steps == [.inserted(after: 0), .inserted(after: 1)])

        let toEmpty = LineAlignment.align(before: [1, 2], after: [])
        #expect(toEmpty.steps == [.deleted(before: 0), .deleted(before: 1)])
    }

    /// The D cap turns a pathological input into a fallback rather than a hang.
    @Test func alignmentGivesUpRatherThanGrinding() {
        let before = (0 ..< 4000).map { UInt64($0) }
        let after = (0 ..< 4000).map { UInt64($0) + 1_000_000 }
        let result = LineAlignment.align(before: before, after: after, maximumEditDistance: 32)
        #expect(result.gaveUp)
        #expect(result.steps.count == 4000, "the fallback must still pair every line up")
    }
}
