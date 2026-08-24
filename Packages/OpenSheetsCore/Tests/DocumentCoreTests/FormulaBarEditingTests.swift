import AppKit
import DocumentCore
import Foundation
import GlassUI
import GridKit
import SheetFormat
import SheetStore
import SheetModel
import TestSupport
import Testing

/// The formula bar as a field you can type in.
///
/// # What was wrong
///
/// Three defects compounded into "clicking the formula box does nothing". The bar was fed
/// `cell.formula` alone, so every text cell and every typed number showed a **blank** bar; the
/// click ran `grid.beginEdit()`, which opens the editor *in the cell*, so the bar never took the
/// caret; and `.textChanged` was `break`, so anything typed there was dropped.
///
/// # What is asserted here
///
/// The document layer, which is where all three meet. The bar's text comes from
/// ``DocumentCore/DocumentModel/editText(at:)`` — the same call that seeds the in-cell editor —
/// so the cases below are really one claim stated five ways: *the bar shows what the cell holds*.
/// Then the edit itself: begin, type, commit through the one write path, cancel, refuse.
@Suite(.serialized)
@MainActor
struct FormulaBarEditingTests {
    // MARK: - What the bar shows

    /// The case the bug was reported as: a text cell, which used to render as an empty bar
    /// because `FormulaBarState.text` was documented as formula source.
    @Test func aTextCellShowsItsText() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        harness.model.selection.select(CellRef(a1: "A1")!)
        #expect(harness.model.formulaBar.text == "Line item")
        #expect(harness.model.formulaBar.text != "=Line item", "the bar must not invent a formula")
        harness.close()
    }

    /// Round-trippable, not formatted. A cell that reads `1,234.50` on screen edits as `1234.5`,
    /// because putting the formatted string back through the parser is how a number column turns
    /// into a text column.
    @Test func aNumberShowsItsRoundTrippableLiteral() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "B1")!)
        #expect(model.formulaBar.text == "1234.5")

        // And what the cell *displays* is genuinely different, so the assertion above is not a
        // coincidence of an unformatted cell.
        let sheet = try #require(model.workbook[model.activeSheetID])
        let formatter = CellFormatter(styles: model.workbook.styles, dateSystem: model.workbook.meta.dateSystem)
        let displayed = formatter.display(
            of: sheet.cells[CellRef(a1: "B1")!],
            styleID: sheet.cells[CellRef(a1: "B1")!]?.styleID ?? .default
        ).text
        #expect(displayed != model.formulaBar.text, "displayed \(displayed), edited \(model.formulaBar.text)")
        harness.close()
    }

    /// A date's bar text has to survive a round trip: whatever is shown, committing it back
    /// unchanged must leave the same day in the cell rather than a number or a string.
    @Test func aDateSurvivesBeingCommittedBackUnchanged() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        let ref = CellRef(a1: "C1")!
        model.selection.select(ref)

        let before = try #require(model.workbook[model.activeSheetID]?.cells[ref])
        let shown = model.formulaBar.text
        #expect(!shown.isEmpty)

        model.beginFormulaBarEdit()
        model.commitFormulaBarEdit(shown, advance: nil)

        let after = try #require(model.workbook[model.activeSheetID]?.cells[ref])
        #expect(after.value == before.value, "the same serial, so the same day")
        #expect(model.workbook.styles.isDateTime(after.styleID), "and still formatted as a date")
        harness.close()
    }

    @Test func aFormulaCellShowsItsSourceWithTheEqualsSign() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        harness.model.selection.select(CellRef(a1: "D1")!)
        #expect(harness.model.formulaBar.text == "=SUM(B1:B3)")
        harness.close()
    }

    @Test func anEmptyCellShowsAnEmptyBarThatIsStillEditable() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "Z40")!)
        #expect(model.formulaBar.text.isEmpty)
        #expect(model.formulaBar.isEditable)

        #expect(model.beginFormulaBarEdit())
        model.formulaBarTextChanged("typed into an empty cell")
        #expect(model.commitFormulaBarEdit("typed into an empty cell", advance: nil))
        #expect(model.editText(at: CellRef(a1: "Z40")!) == "typed into an empty cell")
        harness.close()
    }

    /// The bar and the in-cell editor read from one function, so they cannot disagree.
    @Test func theBarAndTheCellEditorSeedFromTheSameString() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        for a1 in ["A1", "B1", "C1", "D1", "Z40"] {
            model.selection.select(CellRef(a1: a1)!)
            #expect(model.formulaBar.text == model.editText(at: CellRef(a1: a1)!), "at \(a1)")
        }
        harness.close()
    }

    // MARK: - Editing

    @Test func typingInTheBarAndPressingReturnWritesTheCellAndMovesDown() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A5")!)

        #expect(model.beginFormulaBarEdit())
        #expect(model.formulaBar.isEditing)
        model.formulaBarTextChanged("=1+2")
        #expect(model.formulaBar.text == "=1+2")

        #expect(model.commitFormulaBarEdit("=1+2", advance: .down))
        let cell = try #require(model.workbook[model.activeSheetID]?.cells[CellRef(a1: "A5")!])
        #expect(cell.formula == "1+2")
        #expect(cell.value == .number(3))
        #expect(!model.formulaBar.isEditing, "the edit is over")
        #expect(model.editingRef == nil)
        harness.close()
    }

    /// Undo has to see one edit, not two, and it has to see the *same* edit an in-cell commit
    /// would have made — that is what "one write path" means in practice.
    @Test func aBarCommitIsOneUndoableEditIdenticalToAnInCellOne() async throws {
        let viaBar = try await Harness(name: "bar.xlsx", workbook: Self.mixedWorkbook())
        viaBar.model.selection.select(CellRef(a1: "A6")!)
        viaBar.model.beginFormulaBarEdit()
        viaBar.model.formulaBarTextChanged("=SUM(B1:B3)*2")
        viaBar.model.commitFormulaBarEdit("=SUM(B1:B3)*2", advance: nil)

        let viaCell = try await Harness(name: "cell.xlsx", workbook: Self.mixedWorkbook())
        viaCell.model.selection.select(CellRef(a1: "A6")!)
        viaCell.model.handle(.beginEdit(ref: CellRef(a1: "A6")!, seed: nil))
        viaCell.model.handle(.commitEdit(ref: CellRef(a1: "A6")!, text: "=SUM(B1:B3)*2", advance: nil))

        let ref = CellRef(a1: "A6")!
        #expect(viaBar.model.workbook[viaBar.model.activeSheetID]?.cells[ref]
            == viaCell.model.workbook[viaCell.model.activeSheetID]?.cells[ref])
        #expect(viaBar.model.canUndo)
        #expect(viaBar.model.undoName == viaCell.model.undoName)

        viaBar.model.undo()
        #expect(viaBar.model.workbook[viaBar.model.activeSheetID]?.cells[ref] == nil, "one undo, not two")
        viaBar.close()
        viaCell.close()
    }

    @Test func escapeRestoresWhatTheCellHeld() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A1")!)

        model.beginFormulaBarEdit()
        model.formulaBarTextChanged("something else entirely")
        #expect(model.formulaBar.text == "something else entirely")

        model.cancelFormulaBarEdit()
        #expect(model.formulaBar.text == "Line item", "the bar goes back to the cell's content")
        #expect(!model.formulaBar.isEditing)
        #expect(model.editText(at: CellRef(a1: "A1")!) == "Line item", "and the cell never changed")
        #expect(!model.canUndo, "a cancelled edit is not an edit")
        harness.close()
    }

    @Test func tabCommitsAndMovesRight() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        // A multi-cell selection, whose advance the document walks itself — the single-cell case
        // is the grid navigator's, and is asserted in the live app rather than headlessly.
        model.selection.select(CellRange(a1: "A8:C8")!, active: CellRef(a1: "A8")!)

        model.beginFormulaBarEdit()
        #expect(model.commitFormulaBarEdit("first", advance: .forward))
        #expect(model.selection.active == CellRef(a1: "B8"), "Tab moves along the row")
        #expect(model.editText(at: CellRef(a1: "A8")!) == "first")
        harness.close()
    }

    /// A formula that does not compile is refused **and the text is kept**, because the moment a
    /// user most needs to see what they typed is the moment it did not work.
    @Test func aFormulaThatDoesNotParseIsRefusedAndTheEditStaysOpen() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A9")!)

        model.beginFormulaBarEdit()
        model.formulaBarTextChanged("=SUM(")
        #expect(!model.commitFormulaBarEdit("=SUM(", advance: .down))
        #expect(model.formulaBar.diagnostic != nil)
        #expect(model.formulaBar.isEditing, "the field stays open over the text that failed")
        #expect(model.workbook[model.activeSheetID]?.cells[CellRef(a1: "A9")!] == nil)
        harness.close()
    }

    // MARK: - Two-way sync with the in-cell editor

    /// Typing in the cell shows up in the bar. Driven through ``GridKit/GridEvent`` and the
    /// controller callback, which is the same route the real `CellEditor` takes.
    @Test func typingInTheCellShowsInTheBar() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A1")!)

        model.handle(.beginEdit(ref: CellRef(a1: "A1")!, seed: "S"))
        #expect(model.formulaBar.text == "S", "a type-to-edit seeds the bar too")
        #expect(model.formulaBar.isEditing)

        model.grid.onEditorTextChanged?("Sal")
        #expect(model.formulaBar.text == "Sal")

        model.handle(.commitEdit(ref: CellRef(a1: "A1")!, text: "Salaries", advance: nil))
        #expect(model.formulaBar.text == "Salaries")
        #expect(!model.formulaBar.isEditing)
        harness.close()
    }

    // MARK: - Refusals

    /// Excel's rule, and already the grid's: a cell a spill wrote into shows the **anchor's**
    /// formula, is not editable, and says so when clicked. Showing the spilled number instead
    /// would invite the user to retype it, which is exactly the edit that has to be refused.
    @Test func aSpilledCellIsReadableRefusedAndExplained() async throws {
        let harness = try await Harness(name: "spill.xlsx", workbook: Self.spillWorkbook())
        let model = harness.model

        model.selection.select(CellRef(a1: "E2")!)
        #expect(model.formulaBar.text == "=TRANSPOSE(A2:A4)", "the anchor's formula, not the number in E2")
        #expect(!model.formulaBar.isEditable)
        #expect(model.formulaBar.diagnostic == nil, "unclicked, it is not yet an error")

        #expect(!model.beginFormulaBarEdit(), "refused")
        let refusal = try #require(model.lastEditRefusal)
        #expect(refusal.code == "cell.notIndependentlyEditable")
        let diagnostic = try #require(model.formulaBar.diagnostic)
        #expect(diagnostic.contains("E2"))
        #expect(diagnostic.contains("E1"), "and it names the cell to edit instead")
        #expect(!model.formulaBar.isEditing)
        #expect(model.workbook[model.activeSheetID]?.cells[CellRef(a1: "E2")!]?.value == .number(2))

        // The anchor itself is edited normally.
        model.selection.select(CellRef(a1: "E1")!)
        #expect(model.formulaBar.isEditable)
        #expect(model.beginFormulaBarEdit())
        harness.close()
    }

    /// The same rule, from one place: what the bar refuses is what the grid refuses.
    @Test func theBarAndTheGridRefuseTheSameCells() async throws {
        let harness = try await Harness(name: "spill.xlsx", workbook: Self.spillWorkbook())
        let sheet = try #require(harness.model.workbook[harness.model.activeSheetID])
        let rendered = GridRenderModel(sheet: sheet, styles: harness.model.workbook.styles)
        for a1 in ["E1", "E2", "E3", "A1", "Z9"] {
            let ref = CellRef(a1: a1)!
            #expect(
                (sheet.editRefusal(at: ref) == nil) == (rendered.editRefusal(at: ref) == nil),
                "the two editors disagree about \(a1)"
            )
        }
        harness.close()
    }

    /// A read-only document keeps the bar **readable** — the whole point of it — and refuses the
    /// caret, with the reason rather than in silence.
    ///
    /// The file is made unwritable on disk and the document is left to notice, so `.readOnly`
    /// arrives through ``SheetStore/DocumentSession``'s own probe the way it does for a file
    /// another application has locked, rather than from a flag set by the test.
    @Test func aReadOnlyDocumentIsReadableAndNotEditable() async throws {
        let harness = try await Harness(name: "locked.xlsx", autoRefresh: false, workbook: Self.mixedWorkbook())
        let path = harness.url.path(percentEncoded: false)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        try await harness.waitFor { $0.syncState == .readOnly }

        let model = harness.model
        #expect(!model.isEditable)
        model.selection.select(CellRef(a1: "A1")!)
        #expect(model.formulaBar.text == "Line item", "still readable — that is what a read-only bar is for")
        #expect(!model.formulaBar.isEditable)

        #expect(!model.beginFormulaBarEdit())
        #expect(model.formulaBar.diagnostic != nil, "a click has to be answered, not swallowed")
        #expect(!model.formulaBar.isEditing)
        #expect(!model.commitFormulaBarEdit("nope", advance: nil))
        #expect(model.editText(at: CellRef(a1: "A1")!) == "Line item")
        harness.close()
    }

    // MARK: - Moving the selection while the bar is editing

    /// **Excel's behaviour: the selection moving commits the edit.** The grid already does this
    /// for a click on a cell or a header; this covers the selections that do not come from the
    /// grid — the name box, a defined name, the ⌘K palette.
    @Test func movingTheSelectionCommitsTheEditInFlight() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A10")!)

        model.beginFormulaBarEdit()
        model.formulaBarTextChanged("typed here")

        // The name box, in effect: the selection moves without going through the grid.
        model.selection.select(CellRef(a1: "D12")!)

        #expect(model.editText(at: CellRef(a1: "A10")!) == "typed here", "the typing landed")
        #expect(model.selection.active == CellRef(a1: "D12"), "and the navigation still happened")
        #expect(!model.formulaBar.isEditing)
        #expect(model.formulaBar.text == "", "the bar now describes D12")

        // Undo puts the caret back where the typing happened, not where it ended up.
        model.undo()
        #expect(model.workbook[model.activeSheetID]?.cells[CellRef(a1: "A10")!] == nil)
        #expect(model.selection.active == CellRef(a1: "A10"))
        harness.close()
    }

    @Test func movingTheSelectionCommitsExactlyOnce() async throws {
        let harness = try await Harness(name: "kinds.xlsx", workbook: Self.mixedWorkbook())
        let model = harness.model
        model.selection.select(CellRef(a1: "A11")!)
        model.beginFormulaBarEdit()
        model.formulaBarTextChanged("once")
        model.selection.select(CellRef(a1: "B11")!)

        #expect(model.editText(at: CellRef(a1: "A11")!) == "once")
        model.undo()
        #expect(model.workbook[model.activeSheetID]?.cells[CellRef(a1: "A11")!] == nil)
        #expect(!model.canUndo, "a second recorded edit would still be on the stack")
        harness.close()
    }

    // MARK: - Fixtures

    /// One of every kind the bar has to render: text, a formatted number, a date, a formula, and
    /// the empty cells around them.
    static func mixedWorkbook() throws -> Workbook {
        var currency = CellStyle()
        currency.numberFormatID = 44 // `_("$"* #,##0.00_)…`
        var date = CellStyle()
        date.numberFormatID = 14 // `m/d/yyyy`

        var builder = WorkbookBuilder()
            .sheet("Mixed")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .cell("A1", .text("Line item"))
            .cell("B2", .number(20))
            .cell("B3", .number(30))
            .formula("D1", "SUM(B1:B3)", cached: .number(0))
        builder = builder.withStyle(currency) { id, builder in
            builder.cell("B1", .number(1234.5)).styleID("B1", id)
        }
        builder = builder.withStyle(date) { id, builder in
            builder.cell("C1", .number(45_292)).styleID("C1", id)
        }
        return try builder.build()
    }

    /// `E1` holds a dynamic array over `E1:E3`; `E2` and `E3` are cells it wrote into.
    static func spillWorkbook() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Spill")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .cell("A1", .text("anchorless"))
            .formula("E1", "TRANSPOSE(A2:A4)", cached: .number(1))
            .flags("E1", [.spillAnchor, .arrayFormula])
            .put("E2", Cell(value: .number(2), flags: [.spilledInto, .arrayFormula]))
            .put("E3", Cell(value: .number(3), flags: [.spilledInto, .arrayFormula]))
            .arrayFormula("E1", over: "E1:E3")
            .build()
    }
}
