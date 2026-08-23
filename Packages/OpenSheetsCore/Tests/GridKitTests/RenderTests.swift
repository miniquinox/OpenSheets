import CoreGraphics
import SheetModel
import Testing
@testable import GridKit

@Suite("Rendering")
@MainActor
struct RenderTests {
    /// A sheet with 24pt rows and 76pt columns, so cell `(r, c)` is at `(c * 76, r * 24)`.
    private func model(
        cells: [(String, Cell)] = [],
        theme: GridTheme = .light,
        styles: StyleTable = StyleTable(),
        merges: [CellRange] = [],
        frozen: FrozenPanes = .none,
        zoom: Double = 1,
        options: GridOptions = GridOptions(showsGridlines: false),
        // Parked well off the tested surface by default: the selection stroke and the fill handle
        // are ink too, and a test asserting "nothing was painted here" has to mean it.
        selection: GridSelection = GridSelection(active: CellRef(row: 500, column: 60))
    ) -> GridRenderModel {
        var store = CellStore()
        for (address, cell) in cells {
            guard let ref = CellRef(a1: address) else { continue }
            try? store.setCell(cell, at: ref)
        }
        let sheet = Sheet(id: 1, name: "Render", cells: store, merges: merges, frozen: frozen)
        return GridRenderModel(
            sheet: sheet,
            styles: styles,
            theme: theme,
            options: options,
            geometry: GridGeometry(sheet: sheet, zoom: zoom),
            merges: MergeIndex(merges),
            selection: selection
        )
    }

    private func cellRect(row: Int, column: Int, zoom: Double = 1) -> CGRect {
        CGRect(x: Double(column) * 76 * zoom, y: Double(row) * 24 * zoom, width: 76 * zoom, height: 24 * zoom)
    }

    // MARK: - The basics

    @Test("A blank sheet paints the theme's canvas colour")
    func canvas() {
        let surface = RenderSurface()
        surface.render(model())
        #expect(surface.colour(atX: 10, y: 10) == GridTheme.light.canvasBackground)
        #expect(!surface.hasInk(in: CGRect(x: 0, y: 0, width: 200, height: 100), background: GridTheme.light
                .canvasBackground))
    }

    @Test("Light and dark are different pixels, both drawn")
    func lightAndDark() {
        let content = [("A1", Cell.text("Hello"))]
        let light = RenderSurface(theme: .light)
        light.render(model(cells: content, theme: .light))
        let dark = RenderSurface(theme: .dark)
        dark.render(model(cells: content, theme: .dark))

        #expect(light.colour(atX: 300, y: 200) == GridTheme.light.canvasBackground)
        #expect(dark.colour(atX: 300, y: 200) == GridTheme.dark.canvasBackground)
        #expect(light.fingerprint() != dark.fingerprint())
        // Text is drawn in both, not just on the light one.
        #expect(light.hasInk(in: cellRect(row: 0, column: 0), background: GridTheme.light.canvasBackground))
        #expect(dark.hasInk(in: cellRect(row: 0, column: 0), background: GridTheme.dark.canvasBackground))
    }

    @Test("Text lands inside its own cell, the right way up")
    func textPlacement() {
        let surface = RenderSurface()
        surface.render(model(cells: [("B3", Cell.text("Xy"))]))
        let target = cellRect(row: 2, column: 1)
        #expect(surface.hasInk(in: target, background: GridTheme.light.canvasBackground))
        // Nothing bled into the cell above or to the left.
        #expect(!surface.hasInk(in: cellRect(row: 1, column: 1), background: GridTheme.light.canvasBackground))
        #expect(!surface.hasInk(in: cellRect(row: 2, column: 0), background: GridTheme.light.canvasBackground))
        // Bottom-aligned by default, as Excel is: the ink sits in the lower half of the cell.
        let upper = CGRect(x: target.minX, y: target.minY, width: target.width, height: 6)
        #expect(!surface.hasInk(in: upper, background: GridTheme.light.canvasBackground))
    }

    @Test("Gridlines appear on column and row boundaries")
    func gridlines() {
        let surface = RenderSurface()
        surface.render(model(options: GridOptions(showsGridlines: true)))
        // The boundary between column A and B is at x = 76.
        #expect(surface.hasInk(
            in: CGRect(x: 75.5, y: 40, width: 1.5, height: 8),
            background: GridTheme.light.canvasBackground,
            tolerance: 4
        ))
        #expect(!surface.hasInk(
            in: CGRect(x: 40, y: 40, width: 8, height: 8),
            background: GridTheme.light.canvasBackground,
            tolerance: 4
        ))
    }

    // MARK: - Excel's overflow rules

    @Test("Text spills into an empty neighbour")
    func overflowIntoEmpty() {
        let surface = RenderSurface()
        surface.render(model(cells: [("A1", Cell.text("A string far too long for one column"))]))
        let background = GridTheme.light.canvasBackground
        #expect(surface.hasInk(in: cellRect(row: 0, column: 0), background: background))
        // The point of the rule: the tail is visible in column B, which holds nothing.
        #expect(surface.hasInk(in: cellRect(row: 0, column: 1), background: background))
    }

    @Test("Text is cut off — with no ellipsis — against a neighbour that holds something")
    func overflowBlocked() {
        let surface = RenderSurface()
        surface.render(model(cells: [
            ("A1", Cell.text("A string far too long for one column")),
            ("B1", Cell.text("x")),
        ]))
        let background = GridTheme.light.canvasBackground
        #expect(surface.hasInk(in: cellRect(row: 0, column: 0), background: background))
        // Column B has its own single character near the left edge; the spill must not reach the
        // right-hand end of column B.
        let farSide = CGRect(x: 120, y: 0, width: 32, height: 24)
        #expect(!surface.hasInk(in: farSide, background: background))
    }

    @Test("A number too wide for its column becomes hashes and never spills")
    func hashes() {
        var sheet = Sheet(id: 1, name: "S")
        sheet.columnWidths.setValue(28, in: 0 ... 0)
        try? sheet.cells.setCell(Cell.number(123_456_789.123), at: .origin)
        let built = GridRenderModel(
            sheet: sheet,
            styles: StyleTable(),
            options: GridOptions(showsGridlines: false),
            geometry: GridGeometry(sheet: sheet),
            merges: .empty,
            selection: GridSelection(active: CellRef(row: 500, column: 60))
        )
        let surface = RenderSurface()
        surface.render(built)
        let background = GridTheme.light.canvasBackground
        #expect(surface.hasInk(in: CGRect(x: 0, y: 0, width: 28, height: 24), background: background))
        // A number never spills — the cell to the right is untouched.
        #expect(!surface.hasInk(in: CGRect(x: 30, y: 0, width: 60, height: 24), background: background))
    }

    // MARK: - Merges

    @Test("A merged region paints once, with no interior gridline")
    func mergedCells() {
        let merge = CellRange(rows: 1 ... 2, columns: 1 ... 2)
        let surface = RenderSurface()
        surface.render(model(
            cells: [("B2", Cell.text("Merged"))],
            merges: [merge],
            options: GridOptions(showsGridlines: true)
        ))
        let background = GridTheme.light.canvasBackground
        // The interior vertical boundary (x = 152) is inside the merge and must be clean.
        #expect(!surface.hasInk(
            in: CGRect(x: 151.5, y: 30, width: 1.5, height: 8),
            background: background,
            tolerance: 4
        ))
        // The merge's own outer boundary is still drawn by the neighbouring cells' gridlines.
        #expect(surface.hasInk(
            in: CGRect(x: 227.5, y: 30, width: 1.5, height: 8),
            background: background,
            tolerance: 4
        ))
    }

    @Test("A merged cell's text is centred over the whole span, not over its anchor")
    func mergedText() {
        let merge = CellRange(rows: 0 ... 0, columns: 0 ... 3)
        var styles = StyleTable()
        let centred = styles.intern(CellStyle(alignment: CellAlignment(horizontal: .center)))
        let surface = RenderSurface()
        surface.render(model(
            cells: [("A1", Cell.text("Centre", styleID: centred))],
            styles: styles,
            merges: [merge]
        ))
        let background = GridTheme.light.canvasBackground
        // The span is 4 × 76 = 304pt wide, so centred text sits around x = 152.
        #expect(surface.hasInk(in: CGRect(x: 120, y: 0, width: 64, height: 24), background: background))
        #expect(!surface.hasInk(in: CGRect(x: 0, y: 0, width: 40, height: 24), background: background))
    }

    // MARK: - Frozen panes

    @Test("Each frozen pane draws only its own band")
    func frozenPanes() {
        let frozen = FrozenPanes(frozenRows: 2, frozenColumns: 1)
        let built = model(
            cells: [("A1", Cell.text("Corner")), ("C1", Cell.text("Top")), ("A5", Cell.text("Left"))],
            frozen: frozen
        )
        let background = GridTheme.light.canvasBackground

        let corner = RenderSurface(width: 76, height: 48)
        corner.render(built, pane: .corner)
        #expect(corner.hasInk(in: CGRect(x: 0, y: 0, width: 76, height: 24), background: background))

        // The top pane starts at column B in sheet space, so with no scroll `C1` lands at x = 76.
        let top = RenderSurface(width: 400, height: 48)
        top.render(built, pane: .top)
        #expect(top.hasInk(in: CGRect(x: 76, y: 0, width: 76, height: 24), background: background))
        // `A1` belongs to the corner pane and must not appear here.
        #expect(!top.hasInk(in: CGRect(x: 0, y: 0, width: 70, height: 24), background: background))

        // The left pane starts at row 3; `A5` is two rows into it.
        let left = RenderSurface(width: 76, height: 200)
        left.render(built, pane: .left)
        #expect(left.hasInk(in: CGRect(x: 0, y: 48, width: 76, height: 24), background: background))
        #expect(!left.hasInk(in: CGRect(x: 0, y: 0, width: 76, height: 24), background: background))
    }

    @Test("A merge straddling the frozen boundary is drawn by both panes")
    func mergeAcrossFrozenBoundary() {
        // Two frozen columns; the merge runs from column B to column E, so it crosses the divider.
        let merge = CellRange(rows: 0 ... 0, columns: 1 ... 4)
        let built = model(
            cells: [("B1", Cell.text("Straddles the frozen boundary"))],
            merges: [merge],
            frozen: FrozenPanes(frozenRows: 0, frozenColumns: 2)
        )
        let background = GridTheme.light.canvasBackground

        // The frozen half: the left pane covers columns A–B, and the merge starts in B.
        let left = RenderSurface(width: 152, height: 48)
        left.render(built, pane: .left)
        #expect(left.hasInk(in: CGRect(x: 76, y: 0, width: 76, height: 24), background: background))

        // The scrolling half: the body pane starts at column C, and the merge continues into it.
        let body = RenderSurface(width: 400, height: 48)
        body.render(built, pane: .body)
        #expect(body.hasInk(in: CGRect(x: 0, y: 0, width: 200, height: 24), background: background))
    }

    // MARK: - Zoom and display scale

    @Test("Cells scale with zoom", arguments: [0.5, 1.0, 2.0])
    func zoomLevels(zoom: Double) {
        let built = model(cells: [("A1", Cell.text("Z"))], zoom: zoom)
        #expect(built.geometry.rows.size(ofIndex: 0) == 24 * zoom)
        #expect(built.geometry.columns.size(ofIndex: 0) == 76 * zoom)
        #expect(built.geometry.sheetRect(of: CellRef(row: 2, column: 2))
            == cellRect(row: 2, column: 2, zoom: zoom))

        let surface = RenderSurface()
        surface.render(built)
        #expect(surface.hasInk(
            in: cellRect(row: 0, column: 0, zoom: zoom),
            background: GridTheme.light.canvasBackground
        ))
    }

    @Test("A non-Retina display renders too", arguments: [1.0, 2.0])
    func backingScales(scale: Double) {
        let surface = RenderSurface(scale: scale)
        surface.render(model(cells: [("A1", Cell.text("Hairline"))], options: GridOptions(showsGridlines: true)))
        #expect(surface.hasInk(in: cellRect(row: 0, column: 0), background: GridTheme.light.canvasBackground))
        // The gridline is still one device pixel, wherever that lands.
        #expect(surface.hasInk(
            in: CGRect(x: 74, y: 40, width: 4, height: 8),
            background: GridTheme.light.canvasBackground,
            tolerance: 4
        ))
    }

    // MARK: - Selection and flash

    @Test("The selection washes its range and leaves the active cell clear")
    func selection() {
        var selection = GridSelection()
        selection.select(CellRange(rows: 0 ... 2, columns: 0 ... 2), active: CellRef(row: 1, column: 1))
        let surface = RenderSurface()
        surface.render(model(selection: selection))
        let background = GridTheme.light.canvasBackground
        // A washed cell differs from the canvas...
        #expect(surface.hasInk(in: cellRect(row: 0, column: 0).insetBy(dx: 8, dy: 6), background: background,
                               tolerance: 2))
        // ...while the active cell keeps the canvas colour, so the caret is visible.
        #expect(!surface.hasInk(in: cellRect(row: 1, column: 1).insetBy(dx: 12, dy: 8), background: background,
                                tolerance: 2))
    }

    @Test("A flash tints its cells and fades to nothing")
    func flashTint() {
        var flash = FlashState(duration: 6)
        flash.flash([CellRef(row: 1, column: 1)], at: 0)
        var built = model()
        built.flash = flash

        let background = GridTheme.light.canvasBackground
        built.flashTime = 0
        let lit = RenderSurface()
        lit.render(built)
        #expect(lit.hasInk(in: cellRect(row: 1, column: 1).insetBy(dx: 8, dy: 6), background: background,
                           tolerance: 2))

        built.flashTime = 6
        let faded = RenderSurface()
        faded.render(built)
        #expect(!faded.hasInk(in: cellRect(row: 1, column: 1).insetBy(dx: 8, dy: 6), background: background,
                              tolerance: 2))
    }

    // MARK: - Headers

    @Test("Headers draw letters and numbers, and tint the selection")
    func headers() {
        var selection = GridSelection()
        selection.select(CellRange(rows: 0 ... 0, columns: 1 ... 1), active: CellRef(row: 0, column: 1))
        let built = model(selection: selection)
        let theme = GridTheme.light

        let columns = RenderSurface(width: 400, height: 22)
        columns.renderColumnHeader(built)
        #expect(columns.hasInk(in: CGRect(x: 0, y: 0, width: 76, height: 22), background: theme.headerBackground))
        // Column B holds the active cell, so it is painted with the active accent.
        #expect(columns.colour(atX: 90, y: 4) == theme.headerActiveBackground)

        let rows = RenderSurface(width: 46, height: 200)
        rows.renderRowHeader(built)
        #expect(rows.hasInk(in: CGRect(x: 0, y: 24, width: 46, height: 24), background: theme.headerBackground))
    }

    // MARK: - Honesty markers

    @Test("A stale cached value gets a dotted underline and an external link gets a corner mark")
    func honestyMarkers() {
        let background = GridTheme.light.canvasBackground
        let plain = RenderSurface()
        plain.render(model(cells: [("A1", Cell.number(42))]))
        let plainInk = plain.inkCount(in: CGRect(x: 0, y: 0, width: 76, height: 24), background: background)

        let stale = RenderSurface()
        stale.render(model(cells: [(
            "A1",
            Cell(value: .number(42), formula: "SUM(B1:B2)", flags: .staleCache)
        )]))
        let staleInk = stale.inkCount(in: CGRect(x: 0, y: 0, width: 76, height: 24), background: background)
        #expect(staleInk > plainInk)

        let external = RenderSurface()
        external.render(model(cells: [(
            "A1",
            Cell(value: .number(42), formula: "[1]Sheet1!A1", flags: .externalLink)
        )]))
        // The marker is a triangle in the cell's top-right corner.
        #expect(external.hasInk(in: CGRect(x: 70, y: 0, width: 6, height: 6), background: background))
    }
}
