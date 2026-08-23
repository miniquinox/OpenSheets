import SheetModel
import Testing
@testable import GridKit

/// How the grid treats a cell whose value belongs to somebody else.
///
/// The two halves are inseparable: a spilled-into cell **renders** its value like any other —
/// that is the entire point of a rendering engine, and hiding it would be worse than useless —
/// and it **refuses** to be edited, because the next recalculation would overwrite whatever was
/// typed and because Excel refuses too. Rendering without refusing is an invitation to lose
/// work silently.
@Suite("Spill rendering and edit refusal")
struct SpillRenderingTests {
    /// `A1` holds `SEQUENCE(1,3)` and owns `A1:C1`; `E1` is an ordinary number.
    private func model() -> GridRenderModel {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try? sheet.cells.setCell(
            Cell(value: .number(1), formula: "SEQUENCE(1,3)", flags: [.spillAnchor, .arrayFormula]),
            at: CellRef(a1: "A1")!
        )
        try? sheet.cells.setCell(
            Cell(value: .number(2), flags: [.spilledInto, .arrayFormula]), at: CellRef(a1: "B1")!
        )
        try? sheet.cells.setCell(
            Cell(value: .number(3), flags: [.spilledInto, .arrayFormula]), at: CellRef(a1: "C1")!
        )
        try? sheet.cells.setCell(Cell(value: .number(9)), at: CellRef(a1: "E1")!)
        sheet.arrayFormulaRanges[CellRef(a1: "A1")!] = CellRange(a1: "A1:C1")!
        return GridRenderModel(sheet: sheet, styles: StyleTable(styles: [.default]))
    }

    @Test("A spilled-into cell shows its value like any other cell")
    func spilledCellsRender() {
        let model = model()
        let formatter = CellFormatter(styles: model.styles, theme: model.theme)
        #expect(formatter.display(of: model.sheet.cells[CellRef(a1: "B1")!], styleID: .default).text == "2")
        #expect(formatter.display(of: model.sheet.cells[CellRef(a1: "C1")!], styleID: .default).text == "3")
    }

    @Test("Editing a spilled-into cell is refused, and the refusal names the anchor")
    func editingASpilledCellIsRefused() throws {
        let refusal = try #require(model().editRefusal(at: CellRef(a1: "B1")!))
        #expect(refusal.code == "cell.notIndependentlyEditable")
        #expect(refusal.message.contains("B1"))
        #expect(refusal.message.contains("A1"), "the user has to be told which cell to edit instead")
    }

    @Test("The anchor and unrelated cells stay editable")
    func theAnchorIsStillEditable() {
        let model = model()
        #expect(model.editRefusal(at: CellRef(a1: "A1")!) == nil, "the anchor holds the formula")
        #expect(model.editRefusal(at: CellRef(a1: "E1")!) == nil)
        #expect(model.editRefusal(at: CellRef(a1: "Z9")!) == nil)
    }

    @Test("A legacy array formula's followers are refused for the same reason")
    func legacyArrayFollowersAreAlsoRefused() {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try? sheet.cells.setCell(
            Cell(value: .number(1), formula: "TRANSPOSE(D1:D2)", flags: .arrayFormula), at: CellRef(a1: "A1")!
        )
        try? sheet.cells.setCell(Cell(value: .number(2), flags: .arrayFormula), at: CellRef(a1: "A2")!)
        sheet.arrayFormulaRanges[CellRef(a1: "A1")!] = CellRange(a1: "A1:A2")!
        let model = GridRenderModel(sheet: sheet, styles: StyleTable(styles: [.default]))
        #expect(model.editRefusal(at: CellRef(a1: "A2")!) != nil)
        #expect(model.editRefusal(at: CellRef(a1: "A1")!) == nil)
    }

    @Test("The formula bar shows the anchor's formula for a spilled cell, read only")
    func theFormulaBarPointsAtTheAnchor() {
        let model = model()
        let anchor = model.formulaBarText(at: CellRef(a1: "A1")!)
        #expect(anchor.text == "=SEQUENCE(1,3)")
        #expect(anchor.isEditable)

        let spilled = model.formulaBarText(at: CellRef(a1: "B1")!)
        #expect(spilled.text == "=SEQUENCE(1,3)", "not '2' — retyping the number is the edit we refuse")
        #expect(!spilled.isEditable)
    }

    @Test("The spill region is discoverable for the outline the renderer draws")
    func theRegionIsDiscoverable() {
        let model = model()
        #expect(model.spillRegion(at: CellRef(a1: "B1")!) == CellRange(a1: "A1:C1"))
        #expect(model.spillRegion(at: CellRef(a1: "A1")!) == CellRange(a1: "A1:C1"))
        #expect(model.spillRegion(at: CellRef(a1: "E1")!) == nil)
    }

    @Test("An uncomputed cell renders its placeholder rather than nothing")
    func uncomputedCellsAreVisible() {
        let formatter = CellFormatter(styles: StyleTable(styles: [.default]), theme: .light)
        let uncomputed = Cell(
            value: .error(.unknownName), formula: "MMULT(A1:A2,B1:B2)",
            flags: [.uncomputed, .staleCache, .unsupportedFormula]
        )
        #expect(formatter.display(of: uncomputed, styleID: .default).text == "#NAME?")
        // And the distinction it exists to make: a genuinely blank cell still shows nothing.
        #expect(formatter.display(of: Cell(), styleID: .default).text.isEmpty)
        #expect(formatter.display(of: nil, styleID: .default).text.isEmpty)
    }

    @Test("The formula bar still offers the formula of an uncomputed cell for editing")
    func uncomputedCellsRemainEditable() {
        let formatter = CellFormatter(styles: StyleTable(styles: [.default]), theme: .light)
        let uncomputed = Cell(value: .error(.unknownName), formula: "MMULT(A1:A2,B1:B2)", flags: .uncomputed)
        #expect(formatter.editText(of: uncomputed) == "=MMULT(A1:A2,B1:B2)")
    }
}
