import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// Helpers for building a workbook of formulas quickly.
enum GraphFixture {
    static let sheetID = SheetID(1)

    static func workbook(_ cells: [(String, Cell)]) -> Workbook {
        var sheet = Sheet(id: sheetID, name: "S")
        for (address, cell) in cells {
            guard let ref = CellRef(a1: address) else { continue }
            try? sheet.cells.setCell(cell, at: ref)
        }
        return Workbook(sheets: [sheet])
    }

    static func cell(_ address: String) -> SheetCell {
        SheetCell(sheet: sheetID, ref: CellRef(a1: address) ?? .origin)
    }
}

struct DependencyGraphTests {
    @Test func aWholeColumnDependencyIsOneEdgeAndNotAMillion() {
        // The headline requirement: `SUM(A:A)` names 1,048,576 cells and must cost one edge.
        let workbook = GraphFixture.workbook([
            ("B1", .formula("SUM(A:A)")),
            ("A1", .number(1)),
            ("A1048576", .number(2)),
        ])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.rangeEdgeCount == 1)
        #expect(graph.cellEdgeCount == 0)
        #expect(graph.edgeCount == 1, "one range dependency must be one edge, was \(graph.edgeCount)")
    }

    @Test func aWholeColumnDependencyStillAnswersOverlapQueries() {
        let workbook = GraphFixture.workbook([
            ("B1", .formula("SUM(A:A)")),
            ("A1", .number(1)),
        ])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.dependents(of: GraphFixture.cell("A1")) == [GraphFixture.cell("B1")])
        #expect(graph.dependents(of: GraphFixture.cell("A1048576")) == [GraphFixture.cell("B1")])
        #expect(graph.dependents(of: GraphFixture.cell("B5")).isEmpty)
    }

    @Test func manyWholeColumnFormulasStillCostOneEdgeEach() {
        var cells: [(String, Cell)] = []
        for row in 1 ... 500 {
            cells.append(("C\(row)", .formula("SUM(A:A)+SUM(B:B)")))
        }
        let graph = DependencyGraph(workbook: GraphFixture.workbook(cells))
        #expect(graph.edgeCount == 1000, "500 formulas with two range precedents each is 1,000 edges")
    }

    @Test func singleCellPrecedentsUseCellEdges() {
        let workbook = GraphFixture.workbook([
            ("B1", .formula("A1+A2")),
            ("A1", .number(1)),
            ("A2", .number(2)),
        ])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.cellEdgeCount == 2)
        #expect(graph.rangeEdgeCount == 0)
    }

    @Test func reportsPrecedentsAndDependents() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1*2")),
            ("C1", .formula("B1+SUM(A1:A9)")),
        ])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.precedents(of: GraphFixture.cell("B1")) == [.cell(GraphFixture.cell("A1"))])
        #expect(graph.dependents(of: GraphFixture.cell("B1")) == [GraphFixture.cell("C1")])
        #expect(graph.dependents(of: GraphFixture.cell("A1")).count == 2)
    }

    @Test func volatileFormulasAreFlagged() {
        let workbook = GraphFixture.workbook([
            ("A1", .formula("NOW()")),
            ("A2", .formula("OFFSET(B1,1,0)")),
            ("A3", .formula("INDIRECT(\"B1\")")),
            ("A4", .formula("RAND()")),
            ("A5", .formula("TODAY()")),
            ("A6", .formula("1+1")),
        ])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.volatileCells.count == 5)
        #expect(!graph.volatileCells.contains(GraphFixture.cell("A6")))
    }

    @Test func removingAFormulaRemovesItsEdges() {
        let workbook = GraphFixture.workbook([("B1", .formula("SUM(A:A)")), ("C1", .formula("A1"))])
        var graph = DependencyGraph(workbook: workbook)
        #expect(graph.edgeCount == 2)
        graph.removeFormula(at: GraphFixture.cell("B1"))
        #expect(graph.rangeEdgeCount == 0)
        graph.removeFormula(at: GraphFixture.cell("C1"))
        #expect(graph.edgeCount == 0)
    }

    @Test func aFormulaThatDoesNotParseIsRecordedAsAbsentRatherThanThrowing() {
        let workbook = GraphFixture.workbook([("A1", .formula("SUM(((("))])
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.formula(at: GraphFixture.cell("A1")) == nil)
    }

    @Test func rangeOverlapQueriesAreExactAtTheEdges() {
        let workbook = GraphFixture.workbook([("Z1", .formula("SUM(B2:D4)"))])
        let graph = DependencyGraph(workbook: workbook)
        for inside in ["B2", "D4", "C3", "B4", "D2"] {
            #expect(!graph.dependents(of: GraphFixture.cell(inside)).isEmpty, "\(inside) is inside B2:D4")
        }
        for outside in ["A1", "B1", "E4", "D5", "A3", "E3", "C1", "C5"] {
            #expect(graph.dependents(of: GraphFixture.cell(outside)).isEmpty, "\(outside) is outside B2:D4")
        }
    }
}

struct RecalcTests {
    @Test func recalculatesOnlyWhatDependsOnTheChange() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1+1", cached: .number(2))),
            ("C1", .formula("B1+1", cached: .number(3))),
            ("E1", .number(99)),
            ("F1", .formula("E1+1", cached: .number(100))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(result.visited == [GraphFixture.cell("B1"), GraphFixture.cell("C1")])
        #expect(result.values[GraphFixture.cell("B1")] == .number(2))
        #expect(result.values[GraphFixture.cell("C1")] == .number(3))
        #expect(result.values[GraphFixture.cell("F1")] == nil, "an unrelated formula is never touched")
    }

    @Test func evaluatesInDependencyOrderRatherThanAddressOrder() {
        // C1 feeds B1 feeds A1, so the walk has to run backwards through the addresses.
        let workbook = GraphFixture.workbook([
            ("A1", .formula("B1*2", cached: .number(0))),
            ("B1", .formula("C1*2", cached: .number(0))),
            ("C1", .number(3)),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("C1")])
        #expect(result.values[GraphFixture.cell("B1")] == .number(6))
        #expect(result.values[GraphFixture.cell("A1")] == .number(12))
    }

    @Test func aThreeCellCycleMarksAllThree() {
        let workbook = GraphFixture.workbook([
            ("A1", .formula("C1+1")),
            ("B1", .formula("A1+1")),
            ("C1", .formula("B1+1")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        #expect(result.circular == [
            GraphFixture.cell("A1"), GraphFixture.cell("B1"), GraphFixture.cell("C1"),
        ])
    }

    @Test func aSelfReferenceIsCircular() {
        let workbook = GraphFixture.workbook([("A1", .formula("A1+1"))])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        #expect(result.circular == [GraphFixture.cell("A1")])
    }

    @Test func aCycleThroughARangeIsStillACycle() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("A2", .formula("SUM(A1:A3)")),
            ("A3", .formula("A2*2")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        #expect(result.circular.contains(GraphFixture.cell("A2")))
        #expect(result.circular.contains(GraphFixture.cell("A3")))
    }

    @Test func circularCellsGetTheCircularErrorWhenApplied() {
        var workbook = GraphFixture.workbook([
            ("A1", .formula("B1+1", cached: .number(1))),
            ("B1", .formula("A1+1", cached: .number(2))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculateAll(in: workbook).apply(to: &workbook)
        #expect(workbook[GraphFixture.sheetID]?.cells[CellRef(a1: "A1") ?? .origin]?.value == .error(.circular))
        #expect(workbook[GraphFixture.sheetID]?.cells[CellRef(a1: "B1") ?? .origin]?.value == .error(.circular))
    }

    @Test func aWorkbookWithNoCycleNeverReportsOne() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1+1")),
            ("C1", .formula("A1+B1")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        #expect(engine.recalculateAll(in: workbook).circular.isEmpty)
    }

    @Test func volatileFormulasRecomputeEvenWhenNothingTheyReadChanged() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1+1", cached: .number(2))),
            ("Z1", .formula("NOW()", cached: .number(0))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(result.values[GraphFixture.cell("Z1")] == .number(TestWorkbook.options.now))
        #expect(result.visited.contains(GraphFixture.cell("Z1")))
    }

    @Test func anUnsupportedFunctionKeepsItsCachedValueAndIsNeverOverwritten() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("MMULT(A1,A1)", cached: .number(42))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(result.values[GraphFixture.cell("B1")] == nil)
        result.apply(to: &workbook)
        let cell = workbook[GraphFixture.sheetID]?.cells[CellRef(a1: "B1") ?? .origin]
        #expect(cell?.value == .number(42), "the cached value must survive untouched")
        #expect(cell?.formula == "MMULT(A1,A1)", "and so must the formula")
    }

    @Test func stalenessPropagatesToDependentsRatherThanGuessing() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("MMULT(A1,A1)+A1", cached: .number(42))),
            ("C1", .formula("B1*2", cached: .number(84))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(result.stale[GraphFixture.cell("B1")] != nil)
        guard case .staleInput = result.stale[GraphFixture.cell("C1")] else {
            Issue.record("C1 should be stale because its input is: \(String(describing: result.stale))")
            return
        }
        #expect(result.values[GraphFixture.cell("C1")] == nil, "a stale cell must not get a fresh-looking number")
    }

    @Test func applyingAResultSetsTheStaleFlagAndClearsItWhenTheValueComesBack() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", Cell(value: .number(2), formula: "A1+1", flags: [.staleCache])),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")]).apply(to: &workbook)
        let cell = workbook[GraphFixture.sheetID]?.cells[CellRef(a1: "B1") ?? .origin]
        #expect(cell?.flags.contains(.staleCache) == false)
        #expect(cell?.value == .number(2))
    }

    @Test func anExternalWorkbookReferenceIsUnsupportedRatherThanWrong() {
        let workbook = GraphFixture.workbook([("A1", .formula("[1]Ext!A1*2", cached: .number(7)))])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        guard case .externalWorkbook = result.stale[GraphFixture.cell("A1")] else {
            Issue.record("expected an external-workbook reason")
            return
        }
        #expect(result.values[GraphFixture.cell("A1")] == nil)
    }

    @Test func aThreeDimensionalReferenceIsUnsupported() {
        let workbook = GraphFixture.workbook([("A1", .formula("SUM(S:S2!A1)", cached: .number(7)))])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculateAll(in: workbook)
        #expect(result.stale[GraphFixture.cell("A1")] != nil)
    }

    @Test func changingAFormulaKeepsTheGraphInStep() {
        var workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("A2", .number(10)),
            ("B1", .formula("A1+1", cached: .number(2))),
        ])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        try? workbook.withSheet(GraphFixture.sheetID) { sheet in
            try sheet.cells.setCell(.formula("A2+1"), at: CellRef(a1: "B1") ?? .origin)
        }
        engine.setFormula("A2+1", at: GraphFixture.cell("B1"), in: workbook)
        #expect(engine.graph.dependents(of: GraphFixture.cell("A1")).isEmpty)
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A2")])
        #expect(result.values[GraphFixture.cell("B1")] == .number(11))
    }

    @Test func definedNamesParticipateInTheGraph() {
        var sheet = Sheet(id: GraphFixture.sheetID, name: "S")
        try? sheet.cells.setCell(.number(5), at: CellRef(a1: "A1") ?? .origin)
        try? sheet.cells.setCell(.formula("Total*2"), at: CellRef(a1: "B1") ?? .origin)
        var workbook = Workbook(sheets: [sheet])
        try? workbook.setDefinedName(DefinedName(
            name: "Total",
            target: RangeReference(sheet: GraphFixture.sheetID, range: CellRange(CellRef(a1: "A1") ?? .origin)),
            formula: "S!$A$1"
        ))
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        #expect(engine.graph.dependents(ofName: "TOTAL") == [GraphFixture.cell("B1")])
        let result = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(result.values[GraphFixture.cell("B1")] == .number(10))
    }

    @Test func aDefinedNameHoldingAnExpressionIsExpandedIteratively() {
        var sheet = Sheet(id: GraphFixture.sheetID, name: "S")
        try? sheet.cells.setCell(.number(4), at: CellRef(a1: "A1") ?? .origin)
        try? sheet.cells.setCell(.number(6), at: CellRef(a1: "A2") ?? .origin)
        var workbook = Workbook(sheets: [sheet])
        try? workbook.setDefinedName(DefinedName(name: "Both", formula: "SUM(S!$A$1:$A$2)"))
        let engine = FormulaEngine(options: TestWorkbook.options)
        #expect(engine.evaluate("Both*2", at: GraphFixture.cell("B1"), in: workbook) == .value(.number(20)))
    }

    @Test func anEditToAnUnrelatedSheetDoesNotInvalidateThisOne() {
        var first = Sheet(id: SheetID(1), name: "One")
        try? first.cells.setCell(.number(1), at: .origin)
        var second = Sheet(id: SheetID(2), name: "Two")
        try? second.cells.setCell(.formula("One!A1+1", cached: .number(2)), at: .origin)
        try? second.cells.setCell(.number(5), at: CellRef(row: 1, column: 0))
        let workbook = Workbook(sheets: [first, second])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let result = engine.recalculate(in: workbook, changed: [SheetCell(sheet: SheetID(2), ref: CellRef(row: 1, column: 0))])
        #expect(result.visited.isEmpty)
    }
}

/// The parts of the public surface A8 and A9 call directly.
struct EngineAPITests {
    @Test func aKeystrokePreviewCanSkipTheVolatileCells() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1+1", cached: .number(2))),
            ("Z1", .formula("NOW()", cached: .number(0))),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)

        let preview = engine.recalculate(
            in: workbook, changed: [GraphFixture.cell("A1")], includingVolatile: false
        )
        #expect(preview.visited == [GraphFixture.cell("B1")])
        #expect(engine.isVolatile(at: GraphFixture.cell("Z1")))
        #expect(!engine.isVolatile(at: GraphFixture.cell("B1")))

        let commit = engine.recalculate(in: workbook, changed: [GraphFixture.cell("A1")])
        #expect(commit.visited.contains(GraphFixture.cell("Z1")))
    }

    @Test func tracePrecedentsAndDependentsAreAvailableWithoutTheGraph() {
        let workbook = GraphFixture.workbook([
            ("A1", .number(1)),
            ("B1", .formula("A1*2")),
            ("C1", .formula("B1+1")),
        ])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        #expect(engine.precedents(of: GraphFixture.cell("C1")) == [.cell(GraphFixture.cell("B1"))])
        #expect(engine.dependents(of: GraphFixture.cell("A1")) == [GraphFixture.cell("B1")])
    }

    @Test func aOneShotEvaluationNeedsNoGraphAtAll() {
        let engine = FormulaEngine(options: TestWorkbook.options)
        #expect(engine.evaluate("1+1", at: TestWorkbook.origin, in: TestWorkbook.make()) == .value(.number(2)))
    }

    @Test func settingAFormulaThatDoesNotParseIsRefusedRatherThanStored() {
        let workbook = GraphFixture.workbook([("A1", .number(1))])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let refused = engine.setFormula("SUM((((", at: GraphFixture.cell("B1"), in: workbook)
        #expect(refused == false)
        #expect(engine.graph.formula(at: GraphFixture.cell("B1")) == nil)
        let accepted = engine.setFormula("SUM(A1)", at: GraphFixture.cell("B1"), in: workbook)
        #expect(accepted)
        #expect(engine.graph.formula(at: GraphFixture.cell("B1")) != nil)
    }

    @Test func removingAFormulaIsSpelledAsANilSource() {
        let workbook = GraphFixture.workbook([("A1", .number(1)), ("B1", .formula("A1+1"))])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let removed = engine.setFormula(nil, at: GraphFixture.cell("B1"), in: workbook)
        #expect(removed)
        #expect(engine.dependents(of: GraphFixture.cell("A1")).isEmpty)
    }

    @Test func rebuildRecoversFromASheetRename() {
        var first = Sheet(id: SheetID(1), name: "Old")
        try? first.cells.setCell(.number(3), at: .origin)
        var second = Sheet(id: SheetID(2), name: "Two")
        try? second.cells.setCell(.formula("Old!A1*2", cached: .number(6)), at: .origin)
        var workbook = Workbook(sheets: [first, second])
        var engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        #expect(!engine.dependents(of: SheetCell(sheet: SheetID(1), ref: .origin)).isEmpty)

        try? workbook.renameSheet(SheetID(1), to: "New")
        try? workbook.withSheet(SheetID(2)) { sheet in
            try sheet.cells.setCell(.formula("New!A1*2", cached: .number(6)), at: .origin)
        }
        engine.rebuild(from: workbook)
        #expect(!engine.dependents(of: SheetCell(sheet: SheetID(1), ref: .origin)).isEmpty)
    }
}
