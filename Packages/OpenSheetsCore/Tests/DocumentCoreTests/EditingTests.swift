import DocumentCore
import Foundation
import GridKit
import SheetFormat
import SheetFormula
import SheetModel
import TestSupport
import Testing

/// Editing, undo, and the two things a save depends on: that undo is exact, and that the writer is
/// told what changed and nothing more.
@Suite struct EditingTests {
    // MARK: - The acceptance criterion

    /// *"Undo/redo across 100 mixed operations returns a byte-identical save."*
    ///
    /// Byte-identical is checked the only way that means anything: run A2's writer over the
    /// undone workbook and over the pristine one with the same dirty set, and compare the archives
    /// byte for byte. The writer is a pure function of `(workbook, edits)`, so equal bytes out
    /// proves the workbook value came back exactly — including the parts nothing in the undo path
    /// touches, which is where a "close enough" undo would show up.
    @Test func undoAcrossAHundredMixedOperationsRestoresTheFileExactly() throws {
        // Seeded with a block of real cells, because `Clear` over an empty range is correctly
        // a no-op and a "100 operations" test where twenty of them do nothing is not the test
        // it says it is.
        let pristine = try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [[.text("Item"), .text("Q1")], [.text("Salaries"), .number(100)]])
            .fill("A200:D300", with: .number(1))
            .build()
        var workbook = pristine
        var stack = DocumentUndoStack()
        var selection = GridSelection()
        let sheetID = workbook.sheets[0].id

        var applied = 0
        for step in 0 ..< 100 {
            let edit: DocumentEdit?
            switch step % 5 {
            case 0:
                let ref = CellRef(row: 20 + step, column: step % 8)
                edit = WorkbookEditor.setCells(
                    [ref: Cell.number(Double(step))],
                    on: sheetID, in: &workbook,
                    selectionBefore: selection, selectionAfter: selection,
                    name: "Typing", coalescingKey: nil
                )
            case 1:
                let range = CellRange(
                    start: CellRef(row: 200 + step, column: 0),
                    end: CellRef(row: 200 + step, column: 3)
                )
                edit = WorkbookEditor.clearContents(
                    in: [range], on: sheetID, in: &workbook, selection: selection
                )
            case 2:
                edit = WorkbookEditor.resizeColumns(
                    (step % 6) ... (step % 6), to: Double(60 + step),
                    on: sheetID, in: &workbook, selection: selection
                )
            case 3:
                edit = WorkbookEditor.restyle(
                    [CellRange(CellRef(row: 400 + step, column: 1))],
                    on: sheetID, in: &workbook, selection: selection, name: "Bold"
                ) { $0.font.isBold.toggle() }
            default:
                let payload = ClipboardPayload(
                    rowCount: 1, columnCount: 2,
                    origin: CellRef(row: 0, column: 0),
                    cells: [Cell.text("x\(step)"), Cell.number(Double(step) * 1.5)]
                )
                edit = WorkbookEditor.paste(
                    payload,
                    at: CellRange(CellRef(row: 600 + step, column: 2)),
                    on: sheetID, in: &workbook, selection: selection
                )
            }
            guard let edit else { continue }
            applied += 1
            stack.record(edit)
            selection = edit.selectionAfter
        }

        #expect(applied == 100, "every operation in the mix must actually change something")
        #expect(workbook != pristine)
        let edited = workbook

        while let edit = stack.undo() { edit.apply(.undo, to: &workbook) }
        #expect(workbook == pristine, "undo did not restore the workbook value")
        #expect(try bytes(of: workbook) == (try bytes(of: pristine)))

        while let edit = stack.redo() { edit.apply(.redo, to: &workbook) }
        #expect(workbook == edited, "redo did not restore the edited value")
        #expect(try bytes(of: workbook) == (try bytes(of: edited)))
    }

    private func bytes(of workbook: Workbook) throws -> Data {
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets { tracker.noteCellsChanged(in: sheet, formulasChanged: true) }
        return try XLSXWriter.data(for: workbook, edits: tracker)
    }

    // MARK: - Addendum §2: tell the writer what changed, and nothing more

    /// The bug this prevents: our display default row height is 24 pt, Excel's is 15. Regenerate
    /// `<sheetFormatPr>` because somebody typed a number and every row in the workbook gets 60%
    /// taller.
    @Test func aCellEditMarksOnlyCells() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        let edit = try #require(WorkbookEditor.setCells(
            [CellRef(a1: "B2")!: Cell.number(5)],
            on: sheetID, in: &workbook,
            selectionBefore: GridSelection(), selectionAfter: GridSelection(),
            name: "Typing"
        ))
        #expect(edit.regions == .cells)
    }

    @Test func aColumnResizeMarksOnlyColumns() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        let edit = try #require(WorkbookEditor.resizeColumns(
            1 ... 2, to: 120, on: sheetID, in: &workbook, selection: GridSelection()
        ))
        #expect(edit.regions == .columns)
    }

    @Test func aMergeMarksMergesAndCells() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        let edit = try #require(WorkbookEditor.toggleMerge(
            CellRange(a1: "A1:B2")!, on: sheetID, in: &workbook, selection: GridSelection()
        ))
        #expect(edit.regions.contains(.merges))
        #expect(!edit.regions.contains(.rows))
    }

    @Test func freezingPanesMarksOnlyViews() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        let edit = try #require(WorkbookEditor.setFrozenPanes(
            FrozenPanes(frozenRows: 1, frozenColumns: 0),
            on: sheetID, in: &workbook, selection: GridSelection()
        ))
        #expect(edit.regions == .views)
    }

    // MARK: - Structure

    @Test func insertingRowsRewritesFormulasEverywhere() throws {
        var workbook = try WorkbookBuilder()
            .sheet("Data")
            .rows("A1", [[.number(1)], [.number(2)], [.number(3)]])
            .sheet("Summary")
            .formula("A1", "SUM(Data!A1:A3)", cached: .number(6))
            .build()
        let dataID = workbook.sheets[0].id
        let summaryID = workbook.sheets[1].id

        _ = try WorkbookEditor.structural(
            .insertRows(at: 1, count: 1, on: dataID), in: &workbook, selection: GridSelection()
        )
        #expect(workbook[summaryID]?.cells[.origin]?.formula == "SUM(Data!A1:A4)")
    }

    @Test func deletingAColumnLeavesReferencesAsRefRatherThanClamped() throws {
        var workbook = try WorkbookBuilder()
            .sheet("Data")
            .rows("A1", [[.number(1), .number(2)]])
            .formula("C1", "B1*2", cached: .number(4))
            .build()
        let sheetID = workbook.sheets[0].id

        _ = try WorkbookEditor.structural(
            .deleteColumns(at: 1, count: 1, on: sheetID), in: &workbook, selection: GridSelection()
        )
        let moved = try #require(workbook[sheetID]?.cells[CellRef(a1: "B1")!])
        #expect(moved.formula?.contains("#REF!") == true)
        #expect(moved.value == .error(.invalidReference))
    }

    @Test func aStructuralEditIsExactlyUndoable() throws {
        let pristine = try WorkbookBuilder()
            .sheet("Data")
            .rows("A1", [[.number(1)], [.number(2)], [.number(3)]])
            .definedName("Block", refersTo: "Data!$A$1:$A$3")
            .build()
        var workbook = pristine
        let sheetID = workbook.sheets[0].id

        let edit = try #require(try WorkbookEditor.structural(
            .insertRows(at: 0, count: 2, on: sheetID), in: &workbook, selection: GridSelection()
        ))
        #expect(workbook != pristine)
        edit.apply(.undo, to: &workbook)
        #expect(workbook == pristine)
    }

    // MARK: - Coalescing

    @Test func typingIntoOneCellCoalescesIntoOneUndoStep() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        var stack = DocumentUndoStack()
        let ref = CellRef(a1: "C5")!
        let key = "type:\(sheetID.rawValue):C5"
        let started = ContinuousClock.now

        for (index, text) in ["1", "12", "123"].enumerated() {
            let edit = try #require(WorkbookEditor.setCells(
                [ref: Cell.text(text)],
                on: sheetID, in: &workbook,
                selectionBefore: GridSelection(), selectionAfter: GridSelection(),
                name: "Typing", coalescingKey: key
            ))
            var timed = edit
            timed.recordedAt = started.advanced(by: .milliseconds(index * 100))
            stack.record(timed)
        }
        #expect(stack.undoable.count == 1)

        let undo = stack.undo()
        try #require(undo).apply(.undo, to: &workbook)
        #expect(workbook[sheetID]?.cells[ref] == nil, "one undo must remove the whole typed run")
    }

    @Test func typingIntoTwoCellsDoesNotCoalesce() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        var stack = DocumentUndoStack()
        for column in 0 ..< 2 {
            let ref = CellRef(row: 9, column: column)
            let edit = try #require(WorkbookEditor.setCells(
                [ref: Cell.number(Double(column))],
                on: sheetID, in: &workbook,
                selectionBefore: GridSelection(), selectionAfter: GridSelection(),
                name: "Typing", coalescingKey: "type:\(sheetID.rawValue):\(ref.a1String)"
            ))
            stack.record(edit)
        }
        #expect(stack.undoable.count == 2)
    }

    @Test func refreshClearsTheStack() {
        var stack = DocumentUndoStack()
        stack.record(
            DocumentEdit(
                payload: .cells(sheet: SheetID(1), before: [:], after: [:]),
                sheetBefore: SheetID(1), sheetAfter: SheetID(1),
                selectionBefore: GridSelection(), selectionAfter: GridSelection(),
                name: "Typing"
            )
        )
        #expect(stack.canUndo)
        stack.clear()
        #expect(!stack.canUndo)
        #expect(!stack.canRedo)
    }

    // MARK: - Paste

    @Test func pastingTranslatesFormulasByTheOffset() throws {
        var workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.number(2)], [.number(3)]])
            .formula("B1", "A1*$C$1", cached: .number(2))
            .build()
        let sheetID = workbook.sheets[0].id
        let sheet = try #require(workbook[sheetID])
        let payload = ClipboardPayload.capture(
            CellRange(CellRef(a1: "B1")!), from: sheet, styles: workbook.styles
        )

        _ = WorkbookEditor.paste(
            payload,
            at: CellRange(CellRef(a1: "B2")!),
            on: sheetID, in: &workbook, selection: GridSelection()
        )
        #expect(workbook[sheetID]?.cells[CellRef(a1: "B2")!]?.formula == "A2*$C$1")
    }

    @Test func pasteValuesOnlyDropsTheFormula() throws {
        var workbook = try WorkbookBuilder()
            .sheet("S")
            .formula("A1", "1+1", cached: .number(2))
            .build()
        let sheetID = workbook.sheets[0].id
        let sheet = try #require(workbook[sheetID])
        let payload = ClipboardPayload.capture(
            CellRange(CellRef(a1: "A1")!), from: sheet, styles: workbook.styles
        )

        _ = WorkbookEditor.paste(
            payload,
            at: CellRange(CellRef(a1: "A3")!),
            mode: .valuesOnly,
            on: sheetID, in: &workbook, selection: GridSelection()
        )
        let pasted = try #require(workbook[sheetID]?.cells[CellRef(a1: "A3")!])
        #expect(pasted.formula == nil)
        #expect(pasted.value == .number(2))
    }

    /// *"Paste 100,000 cells completes in < 2 s without beachballing."*
    ///
    /// Measured as work rather than as wall clock where it can be — seven agents share this
    /// machine — but the budget is a wall-clock promise to the user, so the assertion is generous
    /// rather than absent (Wave 1 addendum §8).
    @Test func pastingAHundredThousandCellsIsFastEnough() throws {
        var workbook = try Fixtures.workbook()
        let sheetID = workbook.sheets[0].id
        let columns = 100
        let rows = 1000
        let payload = ClipboardPayload(
            rowCount: rows,
            columnCount: columns,
            origin: .origin,
            cells: (0 ..< rows * columns).map { Cell.number(Double($0)) }
        )
        let destination = CellRange(
            start: CellRef(row: 10, column: 0),
            end: CellRef(row: 10 + rows - 1, column: columns - 1)
        )

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = WorkbookEditor.paste(
                payload, at: destination, on: sheetID, in: &workbook, selection: GridSelection()
            )
        }
        #expect(workbook[sheetID]?.cells[CellRef(row: 10, column: 0)]?.value == .number(0))
        #expect(elapsed < .seconds(6), "paste of 100k cells took \(elapsed)")
    }

    // MARK: - Sort

    @Test func sortOrdersRowsAndKeepsThemTogether() throws {
        var workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [
                [.text("c"), .number(3)],
                [.text("a"), .number(1)],
                [.text("b"), .number(2)],
            ])
            .build()
        let sheetID = workbook.sheets[0].id

        _ = WorkbookEditor.sort(
            CellRange(a1: "A1:B3")!, by: 0, ascending: true, hasHeaderRow: false,
            on: sheetID, in: &workbook, selection: GridSelection()
        )
        let sheet = try #require(workbook[sheetID])
        #expect(sheet.cells[CellRef(a1: "A1")!]?.value == .text("a"))
        #expect(sheet.cells[CellRef(a1: "B1")!]?.value == .number(1))
        #expect(sheet.cells[CellRef(a1: "A3")!]?.value == .text("c"))
        #expect(sheet.cells[CellRef(a1: "B3")!]?.value == .number(3))
    }

    /// Excel's cross-type order: numbers, then text, then booleans, then errors, then blanks —
    /// and blanks stay last whichever way you sort, which is the part people notice.
    @Test func mixedTypesSortInExcelsOrder() throws {
        var workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.error(.notAvailable)], [.boolean(true)], [.text("m")], [.number(5)]])
            .build()
        let sheetID = workbook.sheets[0].id
        _ = WorkbookEditor.sort(
            CellRange(a1: "A1:A5")!, by: 0, ascending: true, hasHeaderRow: false,
            on: sheetID, in: &workbook, selection: GridSelection()
        )
        let sheet = try #require(workbook[sheetID])
        #expect(sheet.cells[CellRef(a1: "A1")!]?.value == .number(5))
        #expect(sheet.cells[CellRef(a1: "A2")!]?.value == .text("m"))
        #expect(sheet.cells[CellRef(a1: "A3")!]?.value == .boolean(true))
        #expect(sheet.cells[CellRef(a1: "A4")!]?.value == .error(.notAvailable))
        #expect(sheet.cells[CellRef(a1: "A5")!] == nil)
    }
}

enum Fixtures {
    static func workbook() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Q4")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Item"), .text("Q1"), .text("Q2")],
                [.text("Salaries"), .number(100), .number(120)],
                [.text("Travel"), .number(10), .number(12)],
            ])
            .build()
    }
}
