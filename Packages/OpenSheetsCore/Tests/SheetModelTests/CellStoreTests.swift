@testable import SheetModel
import Testing

@Suite("CellStore")
struct CellStoreTests {
    private func ref(_ a1: String) throws -> CellRef {
        try #require(CellRef(a1: a1))
    }

    private func range(_ a1: String) throws -> CellRange {
        try #require(CellRange(a1: a1))
    }

    // MARK: - Basics

    @Test("an empty store reports nothing")
    func empty() {
        let store = CellStore()
        #expect(store.isEmpty)
        #expect(store.isEmpty)
        #expect(store.usedRange == nil)
        #expect(store[.origin] == nil)
        #expect(store.cells(in: .entireSheet).isEmpty)
    }

    @Test("set, read, overwrite, remove")
    func lifecycle() throws {
        var store = CellStore()
        let target = try ref("C3")

        try store.setCell(.number(42), at: target)
        #expect(store.count == 1)
        #expect(store[target]?.value == .number(42))
        #expect(store.contains(target))

        try store.setCell(.text("hello"), at: target)
        #expect(store.count == 1, "overwriting must not grow the store")
        #expect(store[target]?.value == .text("hello"))

        let removed = store.removeCell(at: target)
        #expect(removed?.value == .text("hello"))
        #expect(store.isEmpty)
        #expect(store[target] == nil)
        #expect(store.removeCell(at: target) == nil)
    }

    @Test("out-of-range writes throw instead of being dropped")
    func rejectsOffSheetWrites() {
        var store = CellStore()
        #expect(throws: SheetError.self) {
            try store.setCell(.number(1), at: CellRef(row: -1, column: 0))
        }
        #expect(throws: SheetError.self) {
            try store.setCell(.number(1), at: CellRef(row: 0, column: Limits.columnCount))
        }
        #expect(store.isEmpty)
    }

    @Test("cells arriving out of order still read back sorted")
    func outOfOrderInsertion() throws {
        var store = CellStore()
        for column in [5, 1, 9, 0, 3] {
            try store.setCell(.number(Double(column)), at: CellRef(row: 2, column: column))
        }
        let read = store.cells(in: .entireSheet).map(\.ref.column)
        #expect(read == [0, 1, 3, 5, 9])
    }

    @Test("rows arriving out of order still read back sorted")
    func outOfOrderRows() throws {
        var store = CellStore()
        for row in [7, 2, 9, 0, 4] {
            try store.setCell(.number(Double(row)), at: CellRef(row: row, column: 0))
        }
        #expect(store.cells(in: .entireSheet).map(\.ref.row) == [0, 2, 4, 7, 9])
        #expect(store.sortedRowIndices() == [0, 2, 4, 7, 9])
    }

    // MARK: - usedRange

    @Test("usedRange tracks growth and shrinks exactly on removal")
    func usedRangeMaintenance() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: try ref("C3"))
        #expect(store.usedRange?.a1String == "C3")

        try store.setCell(.number(2), at: try ref("A1"))
        #expect(store.usedRange?.a1String == "A1:C3")

        try store.setCell(.number(3), at: try ref("E10"))
        #expect(store.usedRange?.a1String == "A1:E10")

        // Removing an interior cell leaves the bounds alone.
        store.removeCell(at: try ref("C3"))
        #expect(store.usedRange?.a1String == "A1:E10")

        // Removing a corner must recompute, not over-report.
        store.removeCell(at: try ref("E10"))
        #expect(store.usedRange?.a1String == "A1")

        store.removeCell(at: try ref("A1"))
        #expect(store.usedRange == nil)
    }

    @Test("a lone cell at XFD1048576 gives a huge used range and one cell")
    func singleCellAtTheFarCorner() throws {
        var store = CellStore()
        let corner = try ref("XFD1048576")
        try store.setCell(.text("here"), at: corner)
        #expect(store.count == 1)
        #expect(store.usedRange?.a1String == "XFD1048576")
        #expect(store.cells(in: .entireSheet).count == 1)
    }

    @Test("removeCells clears a rectangle and recomputes once")
    func bulkRemoval() throws {
        var store = CellStore()
        for row in 0 ..< 10 {
            for column in 0 ..< 10 {
                try store.setCell(.number(Double(row * 10 + column)), at: CellRef(row: row, column: column))
            }
        }
        #expect(store.count == 100)

        store.removeCells(in: try range("C3:E5"))
        #expect(store.count == 100 - 9)
        #expect(store[try ref("D4")] == nil)
        #expect(store[try ref("F6")] != nil)
        #expect(store.usedRange?.a1String == "A1:J10")

        store.removeCells(in: .entireSheet)
        #expect(store.isEmpty)
        #expect(store.usedRange == nil)
    }

    // MARK: - Queries

    @Test("cells(in:) returns exactly the rectangle, row-major")
    func rectangleQuery() throws {
        var store = CellStore()
        for row in 0 ..< 20 {
            for column in 0 ..< 20 {
                try store.setCell(.number(Double(row * 100 + column)), at: CellRef(row: row, column: column))
            }
        }
        let window = store.cells(in: try range("C3:E5"))
        #expect(window.count == 9)
        #expect(window.first?.ref.a1String == "C3")
        #expect(window.last?.ref.a1String == "E5")
        #expect(window.map(\.ref.a1String) == ["C3", "D3", "E3", "C4", "D4", "E4", "C5", "D5", "E5"])
    }

    @Test("rows(in:) omits empty rows entirely")
    func rowSlices() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try store.setCell(.number(2), at: CellRef(row: 500, column: 3))
        try store.setCell(.number(3), at: CellRef(row: 500, column: 7))

        let slices = store.rows(in: .entireSheet)
        #expect(slices.count == 2)
        #expect(slices.map(\.row) == [0, 500])
        #expect(slices[1].count == 2)
        #expect(slices[1][0].column == 3)
        #expect(slices[1][1].column == 7)
        #expect(Array(slices[1]).map(\.ref.a1String) == ["D501", "H501"])
    }

    @Test("row slices clip to the requested columns")
    func rowSliceClipping() throws {
        var store = CellStore()
        for column in 0 ..< 10 {
            try store.setCell(.number(Double(column)), at: CellRef(row: 4, column: column))
        }
        let slices = store.rows(in: try range("C1:E100"))
        #expect(slices.count == 1)
        #expect(Array(slices[0]).map(\.ref.column) == [2, 3, 4])
    }

    @Test("forEachCell matches cells(in:)")
    func forEachMatchesArrayForm() throws {
        var store = CellStore()
        for index in 0 ..< 50 {
            try store.setCell(.number(Double(index)), at: CellRef(row: index * 3, column: index % 7))
        }
        var collected: [CellRef] = []
        store.forEachCell(in: .entireSheet) { ref, _ in collected.append(ref) }
        #expect(collected == store.cells(in: .entireSheet).map(\.ref))
    }

    // MARK: - Navigation

    @Test("column navigation finds the next populated cell in a row")
    func columnNavigation() throws {
        var store = CellStore()
        for column in [0, 1, 2, 8, 9] {
            try store.setCell(.number(1), at: CellRef(row: 3, column: column))
        }
        #expect(store.firstNonEmptyColumn(inRow: 3, atOrAfter: 0) == 0)
        #expect(store.firstNonEmptyColumn(inRow: 3, atOrAfter: 3) == 8)
        #expect(store.firstNonEmptyColumn(inRow: 3, atOrAfter: 10) == nil)
        #expect(store.lastNonEmptyColumn(inRow: 3, atOrBefore: 5) == 2)
        #expect(store.lastNonEmptyColumn(inRow: 3, atOrBefore: 9) == 9)
        #expect(store.lastNonEmptyColumn(inRow: 3, atOrBefore: 0) == 0)
        #expect(store.firstNonEmptyColumn(inRow: 99, atOrAfter: 0) == nil)
    }

    @Test("row navigation finds the next populated cell in a column")
    func rowNavigation() throws {
        var store = CellStore()
        for row in [0, 1, 2, 40, 41] {
            try store.setCell(.number(1), at: CellRef(row: row, column: 5))
        }
        try store.setCell(.number(1), at: CellRef(row: 20, column: 6))

        #expect(store.firstNonEmptyRow(inColumn: 5, atOrAfter: 0) == 0)
        #expect(store.firstNonEmptyRow(inColumn: 5, atOrAfter: 3) == 40)
        #expect(store.firstNonEmptyRow(inColumn: 5, atOrAfter: 42) == nil)
        #expect(store.lastNonEmptyRow(inColumn: 5, atOrBefore: 30) == 2)
        #expect(store.lastNonEmptyRow(inColumn: 5, atOrBefore: 41) == 41)
        #expect(store.firstNonEmptyRow(inColumn: 6, atOrAfter: 0) == 20)
    }

    // MARK: - Structural edits

    @Test("insertRows moves everything at or below down")
    func insertRows() throws {
        var store = CellStore()
        for row in 0 ..< 5 {
            try store.setCell(.number(Double(row)), at: CellRef(row: row, column: 0))
        }
        try store.insertRows(at: 2, count: 3)

        #expect(store.count == 5)
        #expect(store[CellRef(row: 0, column: 0)]?.value == .number(0))
        #expect(store[CellRef(row: 1, column: 0)]?.value == .number(1))
        #expect(store[CellRef(row: 2, column: 0)] == nil)
        #expect(store[CellRef(row: 3, column: 0)] == nil)
        #expect(store[CellRef(row: 4, column: 0)] == nil)
        #expect(store[CellRef(row: 5, column: 0)]?.value == .number(2))
        #expect(store[CellRef(row: 7, column: 0)]?.value == .number(4))
        #expect(store.usedRange?.a1String == "A1:A8")
    }

    @Test("deleteRows removes the band and pulls the rest up")
    func deleteRows() throws {
        var store = CellStore()
        for row in 0 ..< 6 {
            try store.setCell(.number(Double(row)), at: CellRef(row: row, column: 0))
        }
        try store.deleteRows(at: 1, count: 2)

        #expect(store.count == 4)
        #expect(store[CellRef(row: 0, column: 0)]?.value == .number(0))
        #expect(store[CellRef(row: 1, column: 0)]?.value == .number(3))
        #expect(store[CellRef(row: 3, column: 0)]?.value == .number(5))
        #expect(store.usedRange?.a1String == "A1:A4")
    }

    @Test("insertColumns moves everything at or right of the index across")
    func insertColumns() throws {
        var store = CellStore()
        for column in 0 ..< 4 {
            try store.setCell(.number(Double(column)), at: CellRef(row: 0, column: column))
        }
        try store.insertColumns(at: 1, count: 2)

        #expect(store.count == 4)
        #expect(store[CellRef(row: 0, column: 0)]?.value == .number(0))
        #expect(store[CellRef(row: 0, column: 1)] == nil)
        #expect(store[CellRef(row: 0, column: 3)]?.value == .number(1))
        #expect(store[CellRef(row: 0, column: 5)]?.value == .number(3))
    }

    @Test("deleteColumns removes the band and pulls the rest left")
    func deleteColumns() throws {
        var store = CellStore()
        for column in 0 ..< 5 {
            try store.setCell(.number(Double(column)), at: CellRef(row: 0, column: column))
        }
        try store.deleteColumns(at: 1, count: 2)

        #expect(store.count == 3)
        #expect(store[CellRef(row: 0, column: 0)]?.value == .number(0))
        #expect(store[CellRef(row: 0, column: 1)]?.value == .number(3))
        #expect(store[CellRef(row: 0, column: 2)]?.value == .number(4))
    }

    @Test("an insert that would push data off the sheet is refused, not truncated")
    func refusesToShiftDataOffSheet() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: CellRef(row: Limits.maxRow, column: 0))
        #expect(throws: SheetError.self) { try store.insertRows(at: 0, count: 1) }
        #expect(store.count == 1, "the failed insert must leave the store untouched")

        var wide = CellStore()
        try wide.setCell(.number(1), at: CellRef(row: 0, column: Limits.maxColumn))
        #expect(throws: SheetError.self) { try wide.insertColumns(at: 0, count: 1) }
        #expect(wide.count == 1)
    }

    @Test("an insert below the data is fine even when the sheet is nearly full")
    func insertBelowTheData() throws {
        var store = CellStore()
        try store.setCell(.number(1), at: CellRef(row: 5, column: 0))
        try store.insertRows(at: 100, count: 1000)
        #expect(store[CellRef(row: 5, column: 0)]?.value == .number(1))
    }

    @Test("structural edits reject nonsense arguments")
    func structuralValidation() {
        var store = CellStore()
        #expect(throws: SheetError.self) { try store.insertRows(at: 0, count: 0) }
        #expect(throws: SheetError.self) { try store.insertRows(at: -1, count: 1) }
        #expect(throws: SheetError.self) { try store.deleteColumns(at: Limits.columnCount, count: 1) }
    }

    @Test("structural edits leave formula text alone — that is A3's job")
    func doesNotRewriteFormulas() throws {
        var store = CellStore()
        try store.setCell(.formula("A5*2", cached: .number(10)), at: CellRef(row: 0, column: 1))
        try store.insertRows(at: 0, count: 1)
        #expect(store[CellRef(row: 1, column: 1)]?.formula == "A5*2")
    }

    // MARK: - Row hashing

    @Test("row hashes are stable, content-sensitive, and style-blind")
    func rowHashing() throws {
        var first = CellStore()
        try first.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try first.setCell(.text("x"), at: CellRef(row: 0, column: 1))

        var second = CellStore()
        try second.setCell(.number(1), at: CellRef(row: 0, column: 0))
        try second.setCell(.text("x"), at: CellRef(row: 0, column: 1))

        #expect(first.rowContentHash(0) == second.rowContentHash(0))
        #expect(first.rowContentHash(1) == nil)

        // A reformat is not a content change.
        var restyled = second
        try restyled.setCell(Cell(value: .number(1), styleID: StyleID(7)), at: CellRef(row: 0, column: 0))
        #expect(restyled.rowContentHash(0) == first.rowContentHash(0))

        // A value change is.
        var edited = second
        try edited.setCell(.number(2), at: CellRef(row: 0, column: 0))
        #expect(edited.rowContentHash(0) != first.rowContentHash(0))

        // So is a column shift with the same values.
        var shifted = CellStore()
        try shifted.setCell(.number(1), at: CellRef(row: 0, column: 1))
        try shifted.setCell(.text("x"), at: CellRef(row: 0, column: 2))
        #expect(shifted.rowContentHash(0) != first.rowContentHash(0))
    }

    // MARK: - Value semantics

    @Test("copies are independent")
    func valueSemantics() throws {
        var original = CellStore()
        try original.setCell(.number(1), at: .origin)
        var copy = original
        try copy.setCell(.number(2), at: .origin)
        try copy.setCell(.number(3), at: CellRef(row: 5, column: 5))

        #expect(original[.origin]?.value == .number(1))
        #expect(original.count == 1)
        #expect(copy[.origin]?.value == .number(2))
        #expect(copy.count == 2)
        #expect(original != copy)
    }

    @Test("blank-but-styled cells are stored, because formatting is real content")
    func styledEmptyCellsSurvive() throws {
        var store = CellStore()
        try store.setCell(.styled(StyleID(3)), at: try ref("D1"))
        #expect(store.count == 1)
        #expect(store[try ref("D1")]?.styleID == StyleID(3))
        #expect(store.usedRange?.a1String == "D1")
    }
}
