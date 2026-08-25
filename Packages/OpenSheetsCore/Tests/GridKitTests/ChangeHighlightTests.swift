import Foundation
import SheetModel
import Testing
@testable import GridKit

/// Pixels for the standing green/amber/red change tints.
///
/// The assertions are deliberately about **relationships between channels** rather than exact
/// RGB triples. A tint is a 14% wash, so the absolute values depend on the canvas underneath it
/// and on whatever GlassUI eventually hands in for the hues; "the added cell is greener than the
/// canvas and greener than the cell beside it" stays true through both, and is the claim the
/// feature actually makes. The one exact-equality assertion left is the inert case, where
/// byte-identical output is exactly the point.
@Suite("Change highlights")
@MainActor
struct ChangeHighlightTests {
    /// The same 24pt × 76pt sheet the render tests use, so cell `(r, c)` sits at `(c * 76, r * 24)`.
    private func model(
        highlights: ChangeHighlights = .none,
        cells: [(String, Cell)] = [],
        theme: GridTheme = .light,
        merges: [CellRange] = [],
        frozen: FrozenPanes = .none,
        flash: FlashState = FlashState(),
        // Parked off the tested surface: the selection stroke and the fill handle are ink too.
        selection: GridSelection = GridSelection(active: CellRef(row: 500, column: 60))
    ) -> GridRenderModel {
        var store = CellStore()
        for (address, cell) in cells {
            guard let ref = CellRef(a1: address) else { continue }
            try? store.setCell(cell, at: ref)
        }
        let sheet = Sheet(id: 1, name: "Changes", cells: store, merges: merges, frozen: frozen)
        return GridRenderModel(
            sheet: sheet,
            styles: StyleTable(),
            theme: theme,
            options: GridOptions(showsGridlines: false),
            geometry: GridGeometry(sheet: sheet),
            merges: MergeIndex(merges),
            selection: selection,
            highlights: highlights,
            flash: flash,
            flashTime: 0
        )
    }

    private func ref(_ a1: String) -> CellRef {
        guard let parsed = CellRef(a1: a1) else {
            preconditionFailure("\(a1) is not a cell reference")
        }
        return parsed
    }

    /// The middle of cell `(row, column)` in surface points.
    private func centre(row: Int, column: Int) -> (x: Double, y: Double) {
        (x: Double(column) * 76 + 38, y: Double(row) * 24 + 12)
    }

    private func colour(_ surface: RenderSurface, row: Int, column: Int) -> RGBAColor {
        let point = centre(row: row, column: column)
        return surface.colour(atX: point.x, y: point.y)
    }

    /// How far the green channel leads the other two — how green a pixel reads, independent of
    /// how bright the canvas under it is.
    private func greenLead(_ colour: RGBAColor) -> Int {
        Int(colour.green) - max(Int(colour.red), Int(colour.blue))
    }

    /// Every byte of both bitmaps, not a sample of them.
    ///
    /// ``RenderSurface/fingerprint()`` hashes one byte in seven, which is the right trade for
    /// "did this frame change at all". The claims below are stronger than that — *identical* —
    /// and an assertion that can miss six pixels out of seven cannot make them.
    private func identicalPixels(_ lhs: RenderSurface, _ rhs: RenderSurface) -> Bool {
        guard let left = lhs.context.data, let right = rhs.context.data,
              lhs.context.bytesPerRow == rhs.context.bytesPerRow,
              lhs.context.height == rhs.context.height
        else { return false }
        return memcmp(left, right, lhs.context.bytesPerRow * lhs.context.height) == 0
    }

    // MARK: - The inert case

    @Test("No highlights draws exactly what a grid with no highlights at all draws")
    func noneIsInert() {
        let content = [("A1", Cell.text("Hello")), ("C4", Cell.number(42))]
        let without = RenderSurface()
        without.render(model(cells: content))
        let explicitlyNone = RenderSurface()
        explicitlyNone.render(model(highlights: .none, cells: content))

        // Byte-identical, not merely similar: the feature must cost nothing when it is off.
        #expect(identicalPixels(without, explicitlyNone))
        #expect(ChangeHighlights.none.isEmpty)
        #expect(ChangeHighlights.none.cellBounds == nil)

        // And one highlight is enough to change the picture.
        let tinted = RenderSurface()
        tinted.render(model(highlights: ChangeHighlights(added: [ref("A1")]), cells: content))
        #expect(tinted.fingerprint() != without.fingerprint())
    }

    // MARK: - The three colours

    @Test("An added cell reads green, and only that cell does")
    func addedIsGreen() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(added: [ref("B2")])))

        let tinted = colour(surface, row: 1, column: 1)
        #expect(tinted != GridTheme.light.canvasBackground)
        #expect(tinted.green > tinted.red)
        #expect(tinted.green > tinted.blue)
        // The neighbours are untouched — a tint is a statement about one cell.
        #expect(colour(surface, row: 1, column: 0) == GridTheme.light.canvasBackground)
        #expect(colour(surface, row: 0, column: 1) == GridTheme.light.canvasBackground)
    }

    @Test("A modified cell reads amber")
    func modifiedIsAmber() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(modified: [ref("B2")])))

        let tinted = colour(surface, row: 1, column: 1)
        #expect(tinted != GridTheme.light.canvasBackground)
        // Amber is red and green together, against a suppressed blue.
        #expect(tinted.red > tinted.blue)
        #expect(tinted.green > tinted.blue)
        #expect(tinted.red >= tinted.green)
    }

    @Test("A removed cell reads red, on the empty rectangle it left behind")
    func removedIsRed() {
        // Nothing is in B2 — that is the whole point of a removal, and the tint still lands.
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(removed: [ref("B2")])))

        let tinted = colour(surface, row: 1, column: 1)
        #expect(tinted != GridTheme.light.canvasBackground)
        #expect(tinted.red > tinted.green)
        #expect(tinted.red > tinted.blue)
    }

    @Test("The three kinds are three visibly different colours")
    func kindsAreDistinguishable() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(
            added: [ref("A1")], modified: [ref("B1")], removed: [ref("C1")]
        )))
        let added = colour(surface, row: 0, column: 0)
        let modified = colour(surface, row: 0, column: 1)
        let removed = colour(surface, row: 0, column: 2)
        #expect(added != modified)
        #expect(modified != removed)
        #expect(added != removed)
    }

    @Test("Both schemes tint: the same cell reads green on the dark canvas too")
    func darkCanvasTints() {
        let surface = RenderSurface(theme: .dark)
        surface.render(model(highlights: ChangeHighlights(added: [ref("B2")]), theme: .dark))
        let tinted = colour(surface, row: 1, column: 1)
        #expect(tinted != GridTheme.dark.canvasBackground)
        #expect(tinted.green > tinted.red)
        #expect(tinted.green > tinted.blue)
    }

    // MARK: - Bands

    @Test("An inserted row bands the full visible width")
    func insertedRowBand() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(insertedRows: [2])))
        let canvas = GridTheme.light.canvasBackground

        // Both ends of the visible row, and a point in the middle.
        for column in [0, 3, 7] {
            let banded = colour(surface, row: 2, column: column)
            #expect(banded != canvas)
            #expect(banded.green > banded.red)
        }
        // The rows either side are clean.
        #expect(colour(surface, row: 1, column: 3) == canvas)
        #expect(colour(surface, row: 3, column: 3) == canvas)
    }

    @Test("An inserted column bands the full visible height")
    func insertedColumnBand() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(insertedColumns: [1])))
        let canvas = GridTheme.light.canvasBackground

        for row in [0, 5, 11] {
            let banded = colour(surface, row: row, column: 1)
            #expect(banded != canvas)
            #expect(banded.green > banded.red)
        }
        #expect(colour(surface, row: 5, column: 0) == canvas)
        #expect(colour(surface, row: 5, column: 2) == canvas)
    }

    @Test("A new cell inside an inserted row is not tinted twice")
    func bandedAddedCellDoesNotDoubleTint() {
        // Row 2 was inserted, so every cell in it is `added`. If the band and the per-cell fill
        // both landed, the row would come out two shades of green — which reads as two states.
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(
            added: [ref("A3"), ref("B3")], insertedRows: [2]
        )))
        let inBandAndAdded = colour(surface, row: 2, column: 0)
        let inBandOnly = colour(surface, row: 2, column: 5)
        #expect(inBandAndAdded == inBandOnly)

        // An added cell outside any band gets the stronger per-cell wash instead. "Stronger" is
        // the green *lead* over the other channels, not a bigger green number: on a white canvas
        // every channel falls as the wash deepens, green just falls least.
        let elsewhere = RenderSurface()
        elsewhere.render(model(highlights: ChangeHighlights(added: [ref("A3")])))
        let addedOnly = colour(elsewhere, row: 2, column: 0)
        #expect(addedOnly != inBandAndAdded)
        #expect(greenLead(addedOnly) > greenLead(inBandAndAdded))
    }

    @Test("A modified cell inside an inserted row keeps its own amber")
    func modifiedInsideABandStillReadsAmber() {
        let surface = RenderSurface()
        surface.render(model(highlights: ChangeHighlights(modified: [ref("B3")], insertedRows: [2])))
        let tinted = colour(surface, row: 2, column: 1)
        #expect(tinted.red > tinted.blue)
        #expect(tinted.red >= tinted.green)
    }

    // MARK: - Layering

    @Test("A fresh flash reads on top of a standing tint")
    func flashReadsOnTopOfTheTint() {
        let target = ref("B2")
        var flash = FlashState(duration: 6)
        flash.flash([target], at: 0)

        let tintOnly = RenderSurface()
        tintOnly.render(model(highlights: ChangeHighlights(modified: [target])))
        let amber = colour(tintOnly, row: 1, column: 1)
        #expect(amber.red > amber.blue)

        // Same cell, tinted amber *and* flashed at full intensity: the accent has to win, or the
        // agent's latest write is invisible on a cell that has been amber since this morning.
        let both = RenderSurface()
        both.render(model(highlights: ChangeHighlights(modified: [target]), flash: flash))
        let flashed = colour(both, row: 1, column: 1)
        #expect(flashed != amber)
        #expect(flashed.blue > flashed.red)
    }

    @Test("The tint survives the repaint that erases everything under a merge")
    func tintSurvivesTheMergeRepaint() {
        // `drawMerges` fills the whole merged box again to kill the interior gridlines. Anything
        // drawn under it — this tint included — has to be laid back down.
        let merge = CellRange(rows: 1 ... 2, columns: 1 ... 2)
        let surface = RenderSurface()
        surface.render(model(
            highlights: ChangeHighlights(modified: [ref("B2")]),
            cells: [("B2", Cell.text("Merged"))],
            merges: [merge]
        ))
        // The bottom-right corner of the merge, well away from the anchor's own cell rectangle.
        let inside = colour(surface, row: 2, column: 2)
        #expect(inside != GridTheme.light.canvasBackground)
        #expect(inside.red > inside.blue)
    }

    @Test("A merge is tinted once, from its anchor, not four times")
    func mergeIsTintedOnce() {
        // Every covered cell listed as modified: a pass that tinted each of them separately would
        // stack four 14% washes into one much darker rectangle.
        let merge = CellRange(rows: 1 ... 2, columns: 1 ... 2)
        let all = ChangeHighlights(modified: [ref("B2"), ref("C2"), ref("B3"), ref("C3")])
        let many = RenderSurface()
        many.render(model(highlights: all, merges: [merge]))

        let anchorOnly = RenderSurface()
        anchorOnly.render(model(highlights: ChangeHighlights(modified: [ref("B2")]), merges: [merge]))

        #expect(colour(many, row: 2, column: 2) == colour(anchorOnly, row: 2, column: 2))
    }

    @Test("Tints reach a frozen pane")
    func tintsInAFrozenPane() {
        // Two frozen rows and one frozen column: `A1` belongs to the corner pane, `A5` to the
        // left pane. A tint that only ran in the body pane would leave both untinted.
        let frozen = FrozenPanes(frozenRows: 2, frozenColumns: 1)
        let built = model(highlights: ChangeHighlights(added: [ref("A1"), ref("A5")]), frozen: frozen)
        let canvas = GridTheme.light.canvasBackground

        let corner = RenderSurface(width: 76, height: 48)
        corner.render(built, pane: .corner)
        let cornerTint = corner.colour(atX: 38, y: 12)
        #expect(cornerTint != canvas)
        #expect(cornerTint.green > cornerTint.red)

        // The left pane starts at row 3 in sheet space, so `A5` is two rows into it.
        let left = RenderSurface(width: 76, height: 200)
        left.render(built, pane: .left)
        let leftTint = left.colour(atX: 38, y: 60)
        #expect(leftTint != canvas)
        #expect(leftTint.green > leftTint.red)
    }

    @Test("Tints scale with zoom")
    func tintsFollowZoom() {
        let sheet = Sheet(id: 1, name: "Zoom")
        let built = GridRenderModel(
            sheet: sheet,
            styles: StyleTable(),
            options: GridOptions(showsGridlines: false),
            geometry: GridGeometry(sheet: sheet, zoom: 2),
            merges: .empty,
            selection: GridSelection(active: CellRef(row: 500, column: 60)),
            highlights: ChangeHighlights(added: [ref("A1")])
        )
        let surface = RenderSurface()
        surface.render(built)
        // At 2× the cell is 152 × 48, so a point that would be in B2 at 100% is still inside A1.
        let inside = surface.colour(atX: 100, y: 40)
        #expect(inside != GridTheme.light.canvasBackground)
        #expect(surface.colour(atX: 200, y: 40) == GridTheme.light.canvasBackground)
    }

    // MARK: - Cost

    @Test("Changes below the fold cost nothing at all")
    func offScreenChangesAreFree() {
        // Fifty thousand changed cells, none of them on screen. The frame must be identical to
        // one with no highlights — same pixels, same work — or the tint pass is walking the set.
        var farAway: Set<CellRef> = []
        for row in 5000 ..< 55_000 { farAway.insert(CellRef(row: row, column: 3)) }

        let clean = RenderSurface()
        let cleanWork = GridWork.measured {
            clean.render(model())
            return GridInstrumentation.snapshot()
        }

        let loaded = RenderSurface()
        let loadedWork = GridWork.measured {
            loaded.render(model(highlights: ChangeHighlights(modified: farAway)))
            return GridInstrumentation.snapshot()
        }

        #expect(identicalPixels(clean, loaded))
        #expect(cleanWork.axisLookups == loadedWork.axisLookups)
        #expect(cleanWork.cellLookups == loadedWork.cellLookups)
    }

    @Test("Frame cost tracks the viewport, not the size of the change set")
    func costTracksTheViewport() {
        // The visible rectangle of a 600 × 300 surface, every cell of it changed.
        var onScreen: Set<CellRef> = []
        for row in 0 ... 12 {
            for column in 0 ... 7 { onScreen.insert(CellRef(row: row, column: column)) }
        }
        // The same screenful, plus a quarter of a million changes nobody can see.
        var everything = onScreen
        for row in 1000 ..< 6000 {
            for column in 0 ... 49 { everything.insert(CellRef(row: row, column: column)) }
        }
        #expect(everything.count > onScreen.count * 1000)

        func work(_ highlights: ChangeHighlights) -> (RenderSurface, GridInstrumentation.Snapshot) {
            let surface = RenderSurface()
            surface.render(model(highlights: highlights)) // warm the caches
            return GridWork.measured {
                surface.render(model(highlights: highlights))
                return (surface, GridInstrumentation.snapshot())
            }
        }

        let small = work(ChangeHighlights(modified: onScreen))
        let large = work(ChangeHighlights(modified: everything))
        // A 1,000× larger change set is the same frame, to the pixel and to the lookup.
        #expect(small.1.axisLookups == large.1.axisLookups)
        #expect(small.1.cellLookups == large.1.cellLookups)
        #expect(identicalPixels(small.0, large.0))
    }

    // MARK: - The value type

    @Test("The bounding box follows the sets, however they are filled")
    func boundsFollowMutation() {
        // The renderer trusts `cellBounds` to decide what to iterate, so a set that grows after
        // construction and leaves the box behind is a silently missing tint.
        var highlights = ChangeHighlights(added: [ref("B2")])
        #expect(highlights.cellBounds == CellRange(rows: 1 ... 1, columns: 1 ... 1))

        highlights.modified.insert(ref("E9"))
        #expect(highlights.cellBounds == CellRange(rows: 1 ... 8, columns: 1 ... 4))

        highlights.removed = [ref("A1")]
        #expect(highlights.cellBounds == CellRange(rows: 0 ... 8, columns: 0 ... 4))

        highlights.added = []
        highlights.modified = []
        highlights.removed = []
        #expect(highlights.cellBounds == nil)
        #expect(highlights.isEmpty)
    }

    @Test("Bands alone are not empty, and carry no cell bounds")
    func bandsWithoutCells() {
        let bandOnly = ChangeHighlights(insertedRows: [4])
        #expect(!bandOnly.isEmpty)
        #expect(bandOnly.cellBounds == nil)
        #expect(bandOnly.isBanded(CellRef(row: 4, column: 900)))
        #expect(!bandOnly.isBanded(CellRef(row: 5, column: 900)))
        #expect(ChangeHighlights(added: [ref("A1")], removed: [ref("B2")]).cellCount == 2)
    }

    @Test("Equality is by value, so an unchanged set does not look like a new one")
    func equality() {
        let one = ChangeHighlights(added: [ref("A1")], insertedRows: [3])
        let same = ChangeHighlights(added: [ref("A1")], insertedRows: [3])
        let different = ChangeHighlights(added: [ref("A2")], insertedRows: [3])
        #expect(one == same)
        #expect(one != different)
        #expect(one != .none)
    }
}
