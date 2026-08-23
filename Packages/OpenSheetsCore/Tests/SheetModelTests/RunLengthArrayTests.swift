@testable import SheetModel
import Testing

@Suite("RunLengthArray")
struct RunLengthArrayTests {
    @Test("a uniform array stores no runs at all")
    func uniform() {
        let array = RunLengthArray(defaultValue: 64.0)
        #expect(array.runCount == 0)
        #expect(array.isUniform)
        #expect(array[0] == 64)
        #expect(array[16_383] == 64)
        #expect(array[999_999] == 64)
        #expect(array[-5] == 64, "negative indices read as the default rather than trapping")
    }

    @Test("three custom columns cost three runs, not sixteen thousand")
    func sparseCost() {
        var widths = RunLengthArray(defaultValue: 64.0)
        widths[0] = 120
        widths[7] = 200
        widths[16_383] = 40
        #expect(widths.runCount == 3)
        #expect(widths[0] == 120)
        #expect(widths[1] == 64)
        #expect(widths[7] == 200)
        #expect(widths[16_383] == 40)
    }

    @Test("adjacent equal runs merge")
    func coalescing() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(5, in: 0 ... 4)
        array.setValue(5, in: 5 ... 9)
        #expect(array.runCount == 1)
        #expect(array.runs[0].range == 0 ... 9)

        array.setValue(5, in: 20 ... 24)
        #expect(array.runCount == 2, "a gap of defaults keeps the runs apart")

        array.setValue(5, in: 10 ... 19)
        #expect(array.runCount == 1, "filling the gap joins all three")
        #expect(array.runs[0].range == 0 ... 24)
    }

    @Test("writing the default value removes runs instead of storing them")
    func writingDefaultRemoves() {
        var array = RunLengthArray(defaultValue: 1.0)
        array.setValue(9, in: 0 ... 99)
        #expect(array.runCount == 1)
        array.setValue(1, in: 0 ... 99)
        #expect(array.runCount == 0)
        #expect(array.isUniform)
    }

    @Test("a write inside a run splits it into three")
    func splicingInsideARun() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 99)
        array.setValue(2, in: 40 ... 49)

        #expect(array.runCount == 3)
        #expect(array[39] == 1)
        #expect(array[40] == 2)
        #expect(array[49] == 2)
        #expect(array[50] == 1)
        #expect(array[99] == 1)
        #expect(array[100] == 0)
    }

    @Test("a write overlapping several runs replaces all of them")
    func splicingAcrossRuns() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 9)
        array.setValue(2, in: 20 ... 29)
        array.setValue(3, in: 40 ... 49)
        #expect(array.runCount == 3)

        array.setValue(7, in: 5 ... 44)
        #expect(array[0] == 1)
        #expect(array[4] == 1)
        #expect(array[5] == 7)
        #expect(array[25] == 7)
        #expect(array[44] == 7)
        #expect(array[45] == 3)
        #expect(array[49] == 3)
        #expect(array[50] == 0)
        #expect(array.runCount == 3)
    }

    @Test("reset returns a span to the default")
    func resetting() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(5, in: 0 ... 99)
        array.reset(10 ... 19)
        #expect(array[9] == 5)
        #expect(array[10] == 0)
        #expect(array[19] == 0)
        #expect(array[20] == 5)
        #expect(array.runCount == 2)

        array.resetAll()
        #expect(array.isUniform)
    }

    @Test("insert shifts runs and grows a straddled one")
    func insertion() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 4)
        array.setValue(2, in: 10 ... 14)

        // Inserting inside a run extends it — Excel gives a new row the height of its neighbours.
        array.insert(at: 2, count: 3)
        #expect(array[0] == 1)
        #expect(array[2] == 1)
        #expect(array[7] == 1)
        #expect(array[8] == 0)
        #expect(array[13] == 2)
        #expect(array[17] == 2)
        #expect(array[18] == 0)
    }

    @Test("insert at a run's start pushes the run along rather than extending it")
    func insertionAtRunStart() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 10 ... 14)
        array.insert(at: 10, count: 5)
        #expect(array[9] == 0)
        #expect(array[14] == 0)
        #expect(array[15] == 1)
        #expect(array[19] == 1)
        #expect(array[20] == 0)
    }

    @Test("insert with an explicit value stamps the new band")
    func insertionWithValue() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 9)
        array.insert(at: 5, count: 2, value: 99)
        #expect(array[4] == 1)
        #expect(array[5] == 99)
        #expect(array[6] == 99)
        #expect(array[7] == 1)
    }

    @Test("remove deletes a band, trims overlaps, and pulls the rest back")
    func removal() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 9)
        array.setValue(2, in: 20 ... 29)

        array.remove(at: 5, count: 10)
        #expect(array[0] == 1)
        #expect(array[4] == 1)
        #expect(array[5] == 0, "the trimmed tail of the first run is gone")
        #expect(array[10] == 2)
        #expect(array[19] == 2)
        #expect(array[20] == 0)
    }

    @Test("removing a whole run drops it")
    func removingAnEntireRun() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 10 ... 19)
        array.remove(at: 10, count: 10)
        #expect(array.isUniform)
    }

    @Test("seeded runs apply in order, later ones winning")
    func seededConstruction() {
        let array = RunLengthArray(
            defaultValue: 0,
            runs: [
                .init(range: 0 ... 9, value: 1),
                .init(range: 5 ... 14, value: 2),
            ]
        )
        #expect(array[4] == 1)
        #expect(array[5] == 2)
        #expect(array[14] == 2)
        #expect(array[15] == 0)
    }

    @Test("runs(in:) clips to the query and skips defaults")
    func clippedRuns() {
        var array = RunLengthArray(defaultValue: 0)
        array.setValue(1, in: 0 ... 9)
        array.setValue(2, in: 100 ... 109)

        let clipped = array.runs(in: 5 ... 104)
        #expect(clipped.count == 2)
        #expect(clipped[0].range == 5 ... 9)
        #expect(clipped[0].value == 1)
        #expect(clipped[1].range == 100 ... 104)
        #expect(clipped[1].value == 2)
        #expect(array.runs(in: 20 ... 30).isEmpty)
    }

    @Test("lastCustomisedIndex reports how far formatting reaches")
    func lastCustomised() {
        var array = RunLengthArray(defaultValue: 0)
        #expect(array.lastCustomisedIndex == nil)
        array.setValue(1, in: 3 ... 7)
        #expect(array.lastCustomisedIndex == 7)
        array.setValue(1, in: 100 ... 100)
        #expect(array.lastCustomisedIndex == 100)
    }

    @Test("boolean arrays work, for hidden rows and columns")
    func booleanArrays() {
        var hidden = RunLengthArray(defaultValue: false)
        hidden.setValue(true, in: 5 ... 9)
        #expect(!hidden[4])
        #expect(hidden[7])
        #expect(!hidden[10])
        #expect(hidden.runCount == 1)
    }

    // MARK: - Geometry, which is what virtualised scrolling depends on

    @Test("offset multiplies default spans rather than walking them")
    func offsetOfIndex() {
        var heights = RunLengthArray(defaultValue: 24.0)
        #expect(heights.offset(ofIndex: 0) == 0)
        #expect(heights.offset(ofIndex: 1) == 24)
        #expect(heights.offset(ofIndex: 1_048_576) == 24 * 1_048_576)

        heights.setValue(50, in: 10 ... 19)
        // Ten rows at 50 instead of 24 adds 260 points before row 20.
        #expect(heights.offset(ofIndex: 20) == 20 * 24 + 260)
        #expect(heights.offset(ofIndex: 10) == 240)
        #expect(heights.offset(ofIndex: 15) == 240 + 5 * 50)
    }

    @Test("extent measures an inclusive band")
    func extentOfRange() {
        var heights = RunLengthArray(defaultValue: 24.0)
        heights.setValue(50, in: 10 ... 19)
        #expect(heights.extent(of: 0 ... 9) == 240)
        #expect(heights.extent(of: 10 ... 19) == 500)
        #expect(heights.extent(of: 5 ... 14) == 5 * 24 + 5 * 50)
    }

    @Test("index(atOffset:) inverts offset(ofIndex:) across the whole sheet")
    func indexAtOffsetIsTheInverse() {
        var heights = RunLengthArray(defaultValue: 24.0)
        heights.setValue(50, in: 10 ... 19)
        heights.setValue(12, in: 1000 ... 1099)

        for index in [0, 1, 9, 10, 15, 19, 20, 999, 1000, 1050, 1099, 1100, 500_000, 1_048_575] {
            let offset = heights.offset(ofIndex: index)
            #expect(
                heights.index(atOffset: offset, limit: Limits.rowCount) == index,
                "offset \(offset) should land on index \(index)"
            )
            // A point just inside the band still resolves to the same index.
            #expect(heights.index(atOffset: offset + 1, limit: Limits.rowCount) == index)
        }
    }

    @Test("index(atOffset:) clamps at both ends")
    func indexAtOffsetClamps() {
        let heights = RunLengthArray(defaultValue: 24.0)
        #expect(heights.index(atOffset: -100, limit: 1000) == 0)
        #expect(heights.index(atOffset: 0, limit: 1000) == 0)
        #expect(heights.index(atOffset: 1_000_000_000, limit: 1000) == 999)
        #expect(heights.index(atOffset: 100, limit: 0) == 0)
    }

    @Test("equality compares what the array answers, not how it got there")
    func equality() {
        var built = RunLengthArray(defaultValue: 0)
        built.setValue(1, in: 0 ... 4)
        built.setValue(1, in: 5 ... 9)

        var direct = RunLengthArray(defaultValue: 0)
        direct.setValue(1, in: 0 ... 9)

        #expect(built == direct)
        #expect(built.runCount == direct.runCount)
    }
}
