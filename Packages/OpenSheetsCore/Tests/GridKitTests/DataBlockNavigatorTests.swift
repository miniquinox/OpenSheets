import CoreGraphics
import SheetModel
import Testing
@testable import GridKit

/// One `⌘`-arrow case: a column of populated indices, where you start, and where Excel lands.
struct JumpCase: Sendable, CustomStringConvertible {
    var name: String
    var populated: [Int]
    var start: Int
    var forward: Bool
    var limit: Int
    var expected: Int

    var description: String { name }
}

@Suite("⌘-arrow lands where Excel lands")
struct DataBlockNavigatorTests {
    /// Three blocks with gaps: `0–2`, `5–6`, `9`, on a 20-long axis.
    static let blocks = [0, 1, 2, 5, 6, 9]

    static let cases: [JumpCase] = [
        // MARK: On data, next cell also data → far end of the block
        .init(name: "top of block → block end", populated: blocks, start: 0, forward: true, limit: 20, expected: 2),
        .init(name: "middle of block → block end", populated: blocks, start: 1, forward: true, limit: 20, expected: 2),
        .init(
            name: "second block, top → block end",
            populated: blocks, start: 5, forward: true, limit: 20, expected: 6
        ),

        // MARK: On data, next cell empty → first cell of the next block
        .init(name: "block end → next block", populated: blocks, start: 2, forward: true, limit: 20, expected: 5),
        .init(
            name: "second block end → third block",
            populated: blocks, start: 6, forward: true, limit: 20, expected: 9
        ),

        // MARK: On empty → next populated cell
        .init(name: "gap → next block", populated: blocks, start: 3, forward: true, limit: 20, expected: 5),
        .init(name: "gap, further in → next block", populated: blocks, start: 4, forward: true, limit: 20, expected: 5),
        .init(name: "gap after block two", populated: blocks, start: 7, forward: true, limit: 20, expected: 9),
        .init(name: "gap directly above data", populated: blocks, start: 8, forward: true, limit: 20, expected: 9),

        // MARK: Nothing beyond → the last index on the axis
        .init(
            name: "last populated cell → end of sheet",
            populated: blocks, start: 9, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "empty below the last block → end of sheet",
            populated: blocks, start: 10, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "already at the last index stays",
            populated: blocks, start: 19, forward: true, limit: 20, expected: 19
        ),

        // MARK: Backwards
        .init(
            name: "from the bottom → last block", populated: blocks,
            start: 19, forward: false, limit: 20, expected: 9
        ),
        .init(
            name: "lone cell, previous empty → block two end",
            populated: blocks, start: 9, forward: false, limit: 20, expected: 6
        ),
        .init(
            name: "block two end, previous data → block two start",
            populated: blocks, start: 6, forward: false, limit: 20, expected: 5
        ),
        .init(
            name: "block two start, previous empty → block one end",
            populated: blocks, start: 5, forward: false, limit: 20, expected: 2
        ),
        .init(name: "gap upwards → block one end", populated: blocks, start: 4, forward: false, limit: 20, expected: 2),
        .init(name: "gap upwards, adjacent", populated: blocks, start: 3, forward: false, limit: 20, expected: 2),
        .init(
            name: "block one end, previous data → block one start",
            populated: blocks, start: 2, forward: false, limit: 20, expected: 0
        ),
        .init(
            name: "inside block one → block start", populated: blocks,
            start: 1, forward: false, limit: 20, expected: 0
        ),
        .init(name: "already at index zero stays", populated: blocks, start: 0, forward: false, limit: 20, expected: 0),

        // MARK: An empty column
        .init(name: "empty column, down", populated: [], start: 0, forward: true, limit: 20, expected: 19),
        .init(
            name: "empty column, down from the middle", populated: [],
            start: 10, forward: true, limit: 20, expected: 19
        ),
        .init(name: "empty column, up", populated: [], start: 10, forward: false, limit: 20, expected: 0),
        .init(name: "empty column, up from the top", populated: [], start: 0, forward: false, limit: 20, expected: 0),

        // MARK: A single populated cell
        .init(name: "lone cell, down off the end", populated: [5], start: 5, forward: true, limit: 20, expected: 19),
        .init(name: "lone cell, up off the start", populated: [5], start: 5, forward: false, limit: 20, expected: 0),
        .init(name: "above a lone cell, down", populated: [5], start: 0, forward: true, limit: 20, expected: 5),
        .init(name: "below a lone cell, up", populated: [5], start: 19, forward: false, limit: 20, expected: 5),
        .init(name: "adjacent above a lone cell", populated: [5], start: 4, forward: true, limit: 20, expected: 5),
        .init(name: "adjacent below a lone cell", populated: [5], start: 6, forward: false, limit: 20, expected: 5),

        // MARK: A completely full column
        .init(
            name: "full column, down",
            populated: Array(0 ..< 20), start: 0, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "full column, down from the middle",
            populated: Array(0 ..< 20), start: 10, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "full column, up",
            populated: Array(0 ..< 20), start: 19, forward: false, limit: 20, expected: 0
        ),

        // MARK: Blocks flush against the ends of the axis
        .init(
            name: "block at the top, down", populated: Array(0 ... 4),
            start: 0, forward: true, limit: 20, expected: 4
        ),
        .init(
            name: "block at the top, off the end",
            populated: Array(0 ... 4), start: 4, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "block at the top, up",
            populated: Array(0 ... 4), start: 4, forward: false, limit: 20, expected: 0
        ),
        .init(
            name: "block at the bottom, down",
            populated: Array(15 ... 19), start: 15, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "block at the bottom, at the very end",
            populated: Array(15 ... 19), start: 19, forward: true, limit: 20, expected: 19
        ),
        .init(
            name: "just above the bottom block",
            populated: Array(15 ... 19), start: 14, forward: true, limit: 20, expected: 15
        ),
        .init(
            name: "bottom block start, up into nothing",
            populated: Array(15 ... 19), start: 15, forward: false, limit: 20, expected: 0
        ),

        // MARK: A real sheet's worth of rows, to prove the answer does not depend on distance
        .init(
            name: "million-row axis, jump to the last row",
            populated: [0, 1, 2], start: 2, forward: true, limit: 1_048_576, expected: 1_048_575
        ),
        .init(
            name: "million-row axis, block at the very bottom",
            populated: [1_048_570, 1_048_575], start: 0, forward: true, limit: 1_048_576, expected: 1_048_570
        ),
        .init(
            name: "million-row axis, upwards from the bottom",
            populated: [3, 1_048_575], start: 1_048_575, forward: false, limit: 1_048_576, expected: 3
        ),

        // MARK: Two adjacent blocks separated by one empty cell
        .init(
            name: "one-cell gap, down from the block end",
            populated: [0, 1, 3, 4], start: 1, forward: true, limit: 20, expected: 3
        ),
        .init(
            name: "one-cell gap, standing in it",
            populated: [0, 1, 3, 4], start: 2, forward: true, limit: 20, expected: 3
        ),
        .init(
            name: "one-cell gap, standing in it going up",
            populated: [0, 1, 3, 4], start: 2, forward: false, limit: 20, expected: 1
        ),
    ]

    @Test("Every block-edge case", arguments: cases)
    func jumps(testCase: JumpCase) {
        let landed = DataBlockNavigator.jump(
            from: testCase.start,
            populated: testCase.populated,
            forward: testCase.forward,
            limit: testCase.limit
        )
        #expect(landed == testCase.expected, "\(testCase.name)")
    }

    @Test("There are at least thirty block-edge cases")
    func caseCount() {
        #expect(Self.cases.count >= 30)
    }

    @Test("A jump costs the same whether the block is at row 3 or row 1,000,000")
    func jumpCostIsIndependentOfDistance() {
        // A contiguous run of a million rows: a walk-the-run implementation would take a million
        // steps here and one step in the small case. The binary search takes the same either way.
        let huge = Array(0 ..< 1_000_000)
        let landed = DataBlockNavigator.jump(from: 0, populated: huge, forward: true, limit: 1_048_576)
        #expect(landed == 999_999)
        let back = DataBlockNavigator.jump(from: 999_999, populated: huge, forward: false, limit: 1_048_576)
        #expect(back == 0)
    }
}

@Suite("Navigator over a real sheet")
@MainActor
struct GridNavigatorSheetTests {
    private func navigator(_ sheet: Sheet) -> GridNavigator {
        let index = DataBlockIndex(cells: sheet.cells)
        return GridNavigator(
            geometry: GridGeometry(sheet: sheet),
            merges: MergeIndex(sheet.merges),
            blocks: index,
            usedRange: sheet.usedRange
        )
    }

    private func sheet(_ refs: [String]) -> Sheet {
        var store = CellStore()
        for text in refs {
            guard let ref = CellRef(a1: text) else { continue }
            try? store.setCell(Cell(value: .number(1)), at: ref)
        }
        return Sheet(id: 1, name: "S", cells: store)
    }

    @Test("⌘↓ walks a column block then jumps to the sheet's last row")
    func columnBlock() {
        let model = sheet(["A1", "A2", "A3", "A7"])
        let nav = navigator(model)
        #expect(nav.destination(from: CellRef(row: 0, column: 0), motion: .blockDown).row == 2)
        #expect(nav.destination(from: CellRef(row: 2, column: 0), motion: .blockDown).row == 6)
        #expect(nav.destination(from: CellRef(row: 6, column: 0), motion: .blockDown).row == Limits.maxRow)
    }

    @Test("⌘→ uses the row axis")
    func rowBlock() {
        let model = sheet(["A1", "B1", "C1", "G1"])
        let nav = navigator(model)
        #expect(nav.destination(from: .origin, motion: .blockRight).column == 2)
        #expect(nav.destination(from: CellRef(row: 0, column: 2), motion: .blockRight).column == 6)
        #expect(nav.destination(from: CellRef(row: 0, column: 6), motion: .blockRight).column == Limits.maxColumn)
    }

    @Test("A blank-but-styled cell does not stop a jump")
    func styledBlankIsNotData() {
        var model = sheet(["A1"])
        // The cell exists and carries formatting, but has no value — Excel skips it.
        try? model.cells.setCell(Cell(value: .empty, styleID: StyleID(3)), at: CellRef(row: 4, column: 0))
        let nav = navigator(model)
        #expect(nav.destination(from: .origin, motion: .blockDown).row == Limits.maxRow)
    }

    @Test("Arrows skip hidden rows")
    func hiddenRows() {
        var model = sheet(["A1"])
        model.hiddenRows.setValue(true, in: 1 ... 3)
        let nav = navigator(model)
        #expect(nav.destination(from: .origin, motion: .down).row == 4)
        #expect(nav.destination(from: CellRef(row: 4, column: 0), motion: .up).row == 0)
    }

    @Test("Moving down from a merged cell clears the whole merge")
    func mergeSkipping() {
        var model = sheet(["A1"])
        model.merges = [CellRange(rows: 0 ... 2, columns: 0 ... 1)]
        let nav = navigator(model)
        #expect(nav.destination(from: .origin, motion: .down) == CellRef(row: 3, column: 0))
        #expect(nav.destination(from: .origin, motion: .right) == CellRef(row: 0, column: 2))
    }

    @Test("Landing inside a merge snaps to its anchor")
    func mergeAnchoring() {
        var model = sheet(["A1"])
        model.merges = [CellRange(rows: 4 ... 6, columns: 0 ... 1)]
        let nav = navigator(model)
        #expect(nav.destination(from: CellRef(row: 7, column: 1), motion: .up) == CellRef(row: 4, column: 0))
    }

    @Test("⌘Home is A1 and ⌘End is the used range's corner")
    func sheetEnds() {
        let model = sheet(["B2", "E9"])
        let nav = navigator(model)
        #expect(nav.destination(from: CellRef(row: 100, column: 5), motion: .sheetStart) == .origin)
        #expect(nav.destination(from: .origin, motion: .sheetEnd) == CellRef(row: 8, column: 4))
    }

    @Test("Page Down moves by a viewport, never by zero")
    func pageDown() {
        let model = sheet(["A1"])
        let nav = navigator(model)
        let landed = nav.destination(
            from: .origin, motion: .pageDown, viewport: CGSize(width: 800, height: 480)
        )
        #expect(landed.row == 20)
        let tiny = nav.destination(from: .origin, motion: .pageDown, viewport: CGSize(width: 10, height: 1))
        #expect(tiny.row == 1)
    }

    @Test("Motion mapping matches the keys Excel uses")
    func keyMapping() {
        #expect(GridHostView.motion(for: 125, command: false) == .down)
        #expect(GridHostView.motion(for: 125, command: true) == .blockDown)
        #expect(GridHostView.motion(for: 115, command: false) == .rowStart)
        #expect(GridHostView.motion(for: 115, command: true) == .sheetStart)
        #expect(GridHostView.motion(for: 119, command: true) == .sheetEnd)
        #expect(GridHostView.motion(for: 121, command: false) == .pageDown)
        #expect(GridHostView.motion(for: 0, command: false) == nil)
    }
}
