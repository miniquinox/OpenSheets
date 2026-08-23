import SheetModel
import Testing
@testable import GridKit

@Suite("Selection")
struct GridSelectionTests {
    private func ref(_ a1: String) -> CellRef {
        CellRef(a1: a1) ?? .origin
    }

    private func range(_ a1: String) -> CellRange {
        CellRange(a1: a1) ?? CellRange(.origin)
    }

    @Test("A new selection is one cell, anchored on itself")
    func single() {
        let selection = GridSelection(active: ref("C3"))
        #expect(selection.isSingleCell)
        #expect(selection.active == ref("C3"))
        #expect(selection.anchor == ref("C3"))
        #expect(selection.cellCount == 1)
    }

    @Test("Extending twice from the same anchor does not creep")
    func extendIsIdempotentAboutTheAnchor() {
        var selection = GridSelection(active: ref("C3"))
        selection.extend(to: ref("E5"))
        #expect(selection.activeRange == range("C3:E5"))
        selection.extend(to: ref("D4"))
        #expect(selection.activeRange == range("C3:D4"))
        selection.extend(to: ref("A1"))
        #expect(selection.activeRange == range("A1:C3"))
        #expect(selection.anchor == ref("C3"))
    }

    @Test("⌘-click adds a disjoint range and moves the caret into it")
    func multiRange() {
        var selection = GridSelection(active: ref("A1"))
        selection.addRange(range("C3:D4"))
        #expect(selection.ranges.count == 2)
        #expect(selection.active == ref("C3"))
        #expect(selection.contains(ref("A1")))
        #expect(selection.contains(ref("D4")))
        #expect(!selection.contains(ref("B2")))
        #expect(selection.boundingRange == range("A1:D4"))
        #expect(selection.cellCount == 5)
    }

    @Test("Selecting a merged cell takes the whole merge")
    func mergeSelection() {
        var selection = GridSelection()
        selection.select(ref("B2"), span: range("B2:D4"))
        #expect(selection.activeRange == range("B2:D4"))
        #expect(selection.active == ref("B2"))
    }

    @Test("Header selection covers a whole row or column")
    func headerSelection() {
        var selection = GridSelection()
        selection.select(CellRange.entireColumn(2), active: CellRef(row: 0, column: 2))
        #expect(selection.coversEntireColumn(2))
        #expect(!selection.coversEntireRow(0))
        #expect(selection.intersectsColumn(2))
        #expect(selection.intersectsRow(999))
    }

    // MARK: - Tab and Enter

    @Test("Tab runs across the selection and wraps to the next row")
    func tabWrap() {
        var selection = GridSelection()
        selection.select(range("B2:D4"), active: ref("B2"))
        var cursor = selection
        let expected = ["C2", "D2", "B3", "C3", "D3", "B4", "C4", "D4", "B2"]
        for address in expected {
            guard let next = cursor.advancingActive(.forward) else {
                Issue.record("Tab produced no move at \(cursor.active.a1String)")
                return
            }
            cursor = next
            #expect(cursor.active == ref(address))
        }
    }

    @Test("Enter runs down the selection and wraps to the next column")
    func enterWrap() {
        var selection = GridSelection()
        selection.select(range("B2:C3"), active: ref("B2"))
        var cursor = selection
        for address in ["B3", "C2", "C3", "B2"] {
            guard let next = cursor.advancingActive(.down) else {
                Issue.record("Enter produced no move")
                return
            }
            cursor = next
            #expect(cursor.active == ref(address))
        }
    }

    @Test("Shift-Tab is the exact inverse")
    func shiftTab() {
        var selection = GridSelection()
        selection.select(range("B2:D3"), active: ref("B2"))
        guard let back = selection.advancingActive(.backward) else {
            Issue.record("Shift-Tab produced no move")
            return
        }
        #expect(back.active == ref("D3"))
    }

    @Test("Tab moves between ranges of a multi-range selection")
    func tabAcrossRanges() {
        var selection = GridSelection()
        selection.select(range("A1:A2"), active: ref("A1"))
        selection.addRange(range("C1:C2"), active: ref("C1"))
        selection.setActive(ref("A2"))
        guard let next = selection.advancingActive(.forward) else {
            Issue.record("Tab produced no move")
            return
        }
        #expect(next.active == ref("C1"))
    }

    @Test("A single-cell selection has nothing to wrap inside")
    func singleCellDoesNotWrap() {
        let selection = GridSelection(active: ref("B2"))
        #expect(selection.advancingActive(.forward) == nil)
    }

    @Test("Escape collapses a multi-range selection to the active range")
    func collapse() {
        var selection = GridSelection(active: ref("A1"))
        selection.addRange(range("C3:D4"))
        selection.collapseToActiveRange()
        #expect(selection.ranges.count == 1)
        #expect(selection.ranges[0] == range("C3:D4"))
    }
}

@Suite("Merge index")
struct MergeIndexTests {
    private func range(_ a1: String) -> CellRange {
        CellRange(a1: a1) ?? CellRange(.origin)
    }

    @Test("An empty index answers without allocating")
    func empty() {
        let index = MergeIndex.empty
        #expect(index.isEmpty)
        #expect(index.merge(containing: .origin) == nil)
        #expect(index.anchor(of: CellRef(row: 5, column: 5)) == CellRef(row: 5, column: 5))
    }

    @Test("Lookups find the covering merge and identify covered cells")
    func lookup() {
        let index = MergeIndex([range("B2:D4"), range("F1:G1"), range("A10:A20")])
        #expect(index.merge(containing: CellRef(a1: "C3") ?? .origin) == range("B2:D4"))
        #expect(index.isCovered(CellRef(a1: "C3") ?? .origin))
        #expect(!index.isCovered(CellRef(a1: "B2") ?? .origin))
        #expect(index.anchor(of: CellRef(a1: "D4") ?? .origin) == CellRef(a1: "B2"))
        #expect(index.merge(containing: CellRef(a1: "E5") ?? .origin) == nil)
        #expect(index.merge(containing: CellRef(a1: "A15") ?? .origin) == range("A10:A20"))
    }

    @Test("Intersecting merges come back in order")
    func intersecting() {
        let index = MergeIndex([range("A1:B2"), range("D1:E2"), range("A5:B6")])
        let hits = index.merges(intersecting: range("A1:Z3"))
        #expect(hits == [range("A1:B2"), range("D1:E2")])
    }

    @Test("Expanding a visible range pulls in merges that start above it")
    func expansion() {
        // This is the bug the method exists to prevent: a merged title that starts two rows above
        // the visible rect still paints into it.
        let index = MergeIndex([range("A1:C10")])
        let expanded = index.expanded(range("A5:C6"))
        #expect(expanded == range("A1:C10"))
    }

    @Test("A thousand merges still answer in a handful of comparisons")
    func manyMerges() {
        let merges = (0 ..< 1000).map { CellRange(rows: ($0 * 3) ... ($0 * 3 + 1), columns: 0 ... 1) }
        let index = MergeIndex(merges)
        #expect(index.count == 1000)
        #expect(index.merge(containing: CellRef(row: 2997, column: 0)) == merges[999])
        #expect(index.merge(containing: CellRef(row: 2, column: 0)) == nil)
    }
}
