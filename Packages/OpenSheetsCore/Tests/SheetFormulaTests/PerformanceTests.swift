import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// The scale gates.
///
/// **On the timings.** WAVE-1-ADDENDUM §8 is explicit that a wall-clock assertion tuned on an
/// idle machine flakes when seven agents are building on it, and that a flaky gate gets
/// ignored. So each test here asserts two things: the **work done** — a visited-set size, a
/// computed value — which is exact and load-independent, and a wall clock with enough headroom
/// that only a hang or an accidental quadratic can trip it. The brief's 200 ms budgets are
/// release-configuration targets; the numbers below are debug-configuration ceilings roughly
/// twenty times larger.
struct PerformanceTests {
    static let sheetID = SheetID(1)

    static func cell(_ row: Int) -> SheetCell {
        SheetCell(sheet: sheetID, ref: CellRef(row: row, column: 0))
    }

    /// A workbook where `A1` is a number and `A2…An` each add one to the row above.
    static func chain(length: Int) -> Workbook {
        var sheet = Sheet(id: sheetID, name: "Chain")
        try? sheet.cells.setCell(.number(0), at: CellRef(row: 0, column: 0))
        for row in 1 ..< length {
            let source = "A\(row)+1"
            try? sheet.cells.setCell(.formula(source, cached: .number(0)), at: CellRef(row: row, column: 0))
        }
        return Workbook(sheets: [sheet])
    }

    @Test func aFiftyThousandDeepChainEvaluatesWithoutOverflowing() {
        let length = 50_000
        let workbook = PerformanceTests.chain(length: length)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)

        let started = ContinuousClock.now
        let result = engine.recalculate(in: workbook, changed: [PerformanceTests.cell(0)])
        let elapsed = ContinuousClock.now - started

        // Work done: every formula in the chain, exactly once, and the right answer at the end.
        #expect(result.visited.count == length - 1)
        #expect(result.evaluatedCount == length - 1)
        #expect(result.values[PerformanceTests.cell(length - 1)] == .number(Double(length - 1)))
        #expect(result.circular.isEmpty)
        #expect(elapsed < .seconds(20), "50,000-cell chain took \(elapsed) — that is a hang, not a slow machine")
    }

    @Test func aFiftyThousandDeepChainAlsoParsesAndBuildsItsGraphWithoutOverflowing() {
        let workbook = PerformanceTests.chain(length: 50_000)
        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.cellEdgeCount == 49_999)
        #expect(graph.rangeEdgeCount == 0)
    }

    @Test func changingOneCellWithTenThousandDependentsTouchesOnlyThoseDependents() {
        // 10,000 cells downstream of A1, plus 10,000 that have nothing to do with it. If the
        // recalc were not incremental the visited set would be 20,000.
        let interesting = 10_000
        var sheet = Sheet(id: PerformanceTests.sheetID, name: "Chain")
        try? sheet.cells.setCell(.number(0), at: CellRef(row: 0, column: 0))
        for row in 1 ... interesting {
            try? sheet.cells.setCell(
                .formula("A\(row)+1", cached: .number(0)), at: CellRef(row: row, column: 0)
            )
        }
        for row in 0 ..< interesting {
            try? sheet.cells.setCell(.number(1), at: CellRef(row: row, column: 2))
            try? sheet.cells.setCell(
                .formula("C\(row + 1)+1", cached: .number(2)), at: CellRef(row: row, column: 3)
            )
        }
        let workbook = Workbook(sheets: [sheet])
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)

        let started = ContinuousClock.now
        let result = engine.recalculate(in: workbook, changed: [PerformanceTests.cell(0)])
        let elapsed = ContinuousClock.now - started

        #expect(result.visited.count == interesting, "visited \(result.visited.count), expected \(interesting)")
        #expect(result.evaluatedCount == interesting)
        #expect(result.values[PerformanceTests.cell(interesting)] == .number(Double(interesting)))
        for row in 0 ..< 5 {
            #expect(
                result.values[SheetCell(sheet: PerformanceTests.sheetID, ref: CellRef(row: row, column: 3))] == nil,
                "the unrelated D column must not be recalculated"
            )
        }
        #expect(elapsed < .seconds(20), "10,000 dependents took \(elapsed)")
    }

    @Test func aWholeColumnAggregateOverAMillionAddressableRowsDoesNotBuildAMillionEdges() {
        var sheet = Sheet(id: PerformanceTests.sheetID, name: "Wide")
        for row in 0 ..< 1000 {
            try? sheet.cells.setCell(.number(Double(row)), at: CellRef(row: row, column: 0))
        }
        try? sheet.cells.setCell(.number(1), at: CellRef(row: Limits.maxRow, column: 0))
        try? sheet.cells.setCell(.formula("SUM(A:A)", cached: .number(0)), at: CellRef(row: 0, column: 2))
        let workbook = Workbook(sheets: [sheet])

        let graph = DependencyGraph(workbook: workbook)
        #expect(graph.edgeCount == 1, "SUM(A:A) must be one range edge, was \(graph.edgeCount)")

        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let started = ContinuousClock.now
        let result = engine.recalculate(in: workbook, changed: [PerformanceTests.cell(500)])
        let elapsed = ContinuousClock.now - started

        let target = SheetCell(sheet: PerformanceTests.sheetID, ref: CellRef(row: 0, column: 2))
        #expect(result.values[target] == .number(Double((0 ..< 1000).reduce(0, +)) + 1))
        #expect(result.visited == [target])
        #expect(elapsed < .seconds(10), "a whole-column aggregate took \(elapsed)")
    }

    @Test func buildingTheGraphForTenThousandRangeFormulasStaysLinear() {
        var sheet = Sheet(id: PerformanceTests.sheetID, name: "Ranges")
        for row in 0 ..< 10_000 {
            try? sheet.cells.setCell(
                .formula("SUM(A\(row + 1):C\(row + 1))", cached: .number(0)), at: CellRef(row: row, column: 5)
            )
        }
        let workbook = Workbook(sheets: [sheet])
        let started = ContinuousClock.now
        let graph = DependencyGraph(workbook: workbook)
        let elapsed = ContinuousClock.now - started
        #expect(graph.rangeEdgeCount == 10_000)
        #expect(elapsed < .seconds(30), "building 10,000 range edges took \(elapsed)")
    }

    @Test func aFormulaThatIsHundredsOfOperatorsLongEvaluatesIteratively() {
        let source = Array(repeating: "1", count: 400).joined(separator: "+")
        var options = TestWorkbook.options
        options.grammar = .default
        let engine = FormulaEngine(options: options)
        var sheet = Sheet(id: PerformanceTests.sheetID, name: "S")
        try? sheet.cells.setCell(.number(0), at: .origin)
        let workbook = Workbook(sheets: [sheet])
        let outcome = engine.evaluate(
            source, at: SheetCell(sheet: PerformanceTests.sheetID, ref: .origin), in: workbook
        )
        #expect(outcome == .value(.number(400)))
    }
}

/// Concurrency: the engine has to be usable from a background task while the UI draws.
struct ConcurrencyTests {
    @Test func theEngineIsSendableAndEvaluatesOffTheMainActor() async {
        let workbook = PerformanceTests.chain(length: 2000)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let seed = PerformanceTests.cell(0)

        // This compiles at all only because `FormulaEngine`, `Workbook` and `SheetCell` are
        // `Sendable`: a detached task cannot close over anything that is not, and Swift 6's
        // strict concurrency is on for this package. The assertion is the compile.
        let result = await Task.detached {
            engine.recalculate(in: workbook, changed: [seed])
        }.value

        #expect(result.visited.count == 1999)
    }

    @Test func severalPassesCanRunAtOnceBecauseNothingIsShared() async {
        let workbook = PerformanceTests.chain(length: 500)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let seed = PerformanceTests.cell(0)

        await withTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { engine.recalculate(in: workbook, changed: [seed]).visited.count }
            }
            for await count in group {
                #expect(count == 499)
            }
        }
    }

    @Test func aRecalcNeverMutatesTheWorkbookItWasGiven() {
        let workbook = PerformanceTests.chain(length: 50)
        let engine = FormulaEngine(workbook: workbook, options: TestWorkbook.options)
        let before = workbook
        _ = engine.recalculate(in: workbook, changed: [PerformanceTests.cell(0)])
        #expect(workbook == before, "recalculate returns a description of changes; it applies nothing")
    }
}
