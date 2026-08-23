import AppKit
import CoreGraphics
import CoreText
import Foundation
import SheetModel

/// Draws one pane of the grid into a `CGContext`.
///
/// # The shape of a frame
///
/// Everything here is proportional to **what is on screen**, never to the sheet:
///
/// 1. Two ``AxisMetrics`` lookups per axis turn the dirty rect into a ``CellRange``.
/// 2. ``CellStore/forEachRow(in:)`` walks only the *populated* rows inside that range, so an
///    empty screenful costs nothing and a full one costs a few thousand cells.
/// 3. Whole-column and whole-row styles are painted from their run-length runs, so "column D is
///    yellow" is one rectangle rather than 1,048,576 cells.
/// 4. Text is shaped through ``TextLayoutCache``, so a fling re-draws but does not re-shape.
///
/// There is no code path in this file that iterates rows or columns of the sheet.
///
/// # Coordinates
///
/// The context is flipped — origin top-left, y growing down — because that is what a document
/// view in an `NSScrollView` gives you and because sheet space is naturally flipped too. Glyphs
/// are counter-flipped through `textMatrix` rather than by transforming the whole context, which
/// keeps every rectangle in one space.
@MainActor
public final class GridRenderer {
    /// Shaped lines, bounded. See ``TextLayoutCache``.
    public let textCache: TextLayoutCache
    /// Wrapped paragraphs, bounded separately.
    public let wrappedCache: WrappedTextCache

    /// The display's scale, so hairlines land on whole device pixels. The view sets it from
    /// `window.backingScaleFactor`; 1.0 is a non-Retina display and must still look right.
    public var backingScale: Double = 2

    private var palette: ResolvedPalette
    private var paletteSource: GridTheme
    private var formatter: CellFormatter

    /// Everything about a style that is the same for every cell using it.
    ///
    /// Resolving this per cell per frame was the single biggest cost in the draw loop, and the
    /// worst part was not obvious: ``StyleTable/numberFormat(id:)`` **parses the format code**
    /// for a built-in id, because ids 0–49 are implicit and are stored as strings. Six hundred
    /// visible cells meant six hundred runs of the format scanner every frame. Copying the
    /// `CellStyle` — a struct with a `String` font name, so an ARC traffic jam — was the second.
    ///
    /// A workbook has a few dozen styles, so this map is tiny and needs no eviction beyond a cap.
    private struct ResolvedStyle {
        var style: CellStyle
        var format: NumberFormat
        var fontKey: FontKey
        var fill: CGColor?
        var hasBorder: Bool
        var hasDecoration: Bool
    }

    private var resolvedStyles: [StyleID: ResolvedStyle] = [:]
    private var resolvedZoom: Double = 1

    /// Formatted text, keyed by what produced it.
    ///
    /// Formatting a number allocates several strings. During a fling the same values recur
    /// constantly — a column of regions, a column of statuses, a bounded set of numbers — so this
    /// turns most of the formatting cost into a dictionary probe.
    private var displayCache: BoundedLRU<DisplayKey, CellDisplay>

    private struct DisplayKey: Hashable {
        var value: CellValue
        var style: StyleID
        /// Hyperlinks colour differently, so they cannot share an entry.
        var isHyperlink: Bool
    }

    /// Reused between frames so a screenful of cells does not allocate a dictionary of arrays.
    private var rowScratch: [Int: [RowEntry]] = [:]

    /// `RGBAColor.cgColor` allocates. Six hundred visible cells meant six hundred allocations a
    /// frame just to set the text colour, for a palette that is usually three colours wide.
    private var cgColors: [RGBAColor: CGColor] = [:]

    public init(theme: GridTheme = .light, textCapacity: Int = 4096) {
        palette = ResolvedPalette(theme)
        paletteSource = theme
        formatter = CellFormatter(styles: StyleTable(), theme: theme)
        textCache = TextLayoutCache(capacity: textCapacity)
        wrappedCache = WrappedTextCache()
        displayCache = BoundedLRU(capacity: 4096)
    }

    /// Drops every cached line. Called when the font or zoom changes wholesale.
    public func invalidateCaches() {
        textCache.removeAll()
        wrappedCache.removeAll()
        displayCache.removeAll()
        resolvedStyles.removeAll(keepingCapacity: true)
        cgColors.removeAll(keepingCapacity: true)
    }

    /// A `CGColor` for a model colour, made once.
    private func cgColor(_ color: RGBAColor) -> CGColor {
        if let existing = cgColors[color] { return existing }
        let made = color.cgColor
        if cgColors.count > 512 { cgColors.removeAll(keepingCapacity: true) }
        cgColors[color] = made
        return made
    }

    // MARK: - Entry point

    /// Draws one pane.
    ///
    /// - Parameters:
    ///   - pane: which quadrant, which decides the rows and columns this call is allowed to touch.
    ///   - context: a flipped context.
    ///   - viewRect: the pane's rectangle in the context's coordinate space.
    ///   - sheetOrigin: the sheet-space point that sits at `viewRect.origin`.
    ///   - model: everything to draw.
    public func draw(
        _ pane: GridPane,
        into context: CGContext,
        viewRect: CGRect,
        sheetOrigin: CGPoint,
        model: GridRenderModel
    ) {
        guard viewRect.width > 0.5, viewRect.height > 0.5 else { return }
        refreshPalette(model)

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewRect)
        context.setFillColor(palette.canvas)
        context.fill(viewRect)

        let offset = CGPoint(x: viewRect.minX - sheetOrigin.x, y: viewRect.minY - sheetOrigin.y)
        let sheetRect = CGRect(origin: sheetOrigin, size: viewRect.size)
        guard let visible = paneRange(pane, sheetRect: sheetRect, model: model) else { return }

        let rows = collectRows(visible, model: model)

        drawBandFills(visible, model: model, context: context, offset: offset)
        drawCellFills(visible, rows: rows, model: model, context: context, offset: offset)
        if model.drawsGridlines {
            drawGridlines(visible, model: model, context: context, offset: offset, clip: viewRect)
        }
        drawMerges(visible, model: model, context: context, offset: offset)
        drawBorders(visible, rows: rows, model: model, context: context, offset: offset)
        drawContent(visible, rows: rows, model: model, context: context, offset: offset)
        drawSelection(visible, model: model, context: context, offset: offset)
    }

    // MARK: - Ranges

    /// The cells this pane may draw: the visible rectangle, clipped to the pane's own band.
    private func paneRange(_ pane: GridPane, sheetRect: CGRect, model: GridRenderModel) -> CellRange? {
        let geometry = model.geometry
        let visible = geometry.cellRange(inSheetRect: sheetRect)

        // A pane with nothing frozen on an axis has no band on that axis, which is not the same
        // as an empty one — `0 ... -1` is not a range, it is a trap.
        let rowLimit: ClosedRange<Int>? = switch pane {
        case .corner, .top:
            geometry.frozenRows > 0 ? 0 ... (geometry.frozenRows - 1) : nil
        case .left, .body:
            geometry.frozenRows ... (geometry.rows.count - 1)
        }
        let columnLimit: ClosedRange<Int>? = switch pane {
        case .corner, .left:
            geometry.frozenColumns > 0 ? 0 ... (geometry.frozenColumns - 1) : nil
        case .top, .body:
            geometry.frozenColumns ... (geometry.columns.count - 1)
        }
        guard let rowLimit, let columnLimit else { return nil }

        let firstRow = max(visible.start.row, rowLimit.lowerBound)
        let lastRow = min(visible.end.row, rowLimit.upperBound)
        let firstColumn = max(visible.start.column, columnLimit.lowerBound)
        let lastColumn = min(visible.end.column, columnLimit.upperBound)
        guard firstRow <= lastRow, firstColumn <= lastColumn else { return nil }
        return CellRange(rows: firstRow ... lastRow, columns: firstColumn ... lastColumn)
    }

    /// One populated cell per entry, ordered by column, for each visible row.
    ///
    /// The two extra probes per row pull in the nearest populated cell just outside the visible
    /// columns, because Excel lets text spill into empty neighbours — and a cell whose text
    /// spills *into view from the left* is one people notice immediately when it is missing.
    private func collectRows(_ visible: CellRange, model: GridRenderModel) -> [Int: [RowEntry]] {
        // Reused frame to frame: a screenful is a few dozen arrays, and allocating them again
        // every frame is a cost that shows up as jitter rather than as a hot function.
        var result = rowScratch
        result.removeAll(keepingCapacity: true)
        result.reserveCapacity(visible.rowCount)
        let store = model.sheet.cells

        store.forEachRow(in: visible) { slice in
            var entries: [RowEntry] = []
            entries.reserveCapacity(slice.count + 2)
            for (ref, cell) in slice {
                entries.append(RowEntry(column: ref.column, cell: cell))
            }
            result[slice.row] = entries
        }

        for row in visible.rows {
            var entries = result[row] ?? []
            if visible.start.column > 0,
               let left = store.lastNonEmptyColumn(inRow: row, atOrBefore: visible.start.column - 1),
               let cell = store[CellRef(row: row, column: left)] {
                entries.insert(RowEntry(column: left, cell: cell), at: 0)
            }
            if visible.end.column < Limits.maxColumn,
               let right = store.firstNonEmptyColumn(inRow: row, atOrAfter: visible.end.column + 1),
               let cell = store[CellRef(row: row, column: right)] {
                entries.append(RowEntry(column: right, cell: cell))
            }
            if !entries.isEmpty { result[row] = entries }
        }
        rowScratch = result
        return result
    }

    struct RowEntry {
        var column: Int
        var cell: Cell
    }

    // MARK: - Backgrounds

    /// Whole-column and whole-row fills, painted from their run-length runs.
    private func drawBandFills(
        _ visible: CellRange,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        if model.options.showsAlternatingRows {
            context.setFillColor(palette.alternating)
            for row in visible.rows where !row.isMultiple(of: 2) {
                let rect = rowRect(row, columns: visible.columns, model: model, offset: offset)
                context.fill(rect)
            }
        }

        for run in model.sheet.columnStyles.runs(in: visible.columns) {
            guard let color = resolved(run.value, model: model).fill else { continue }
            context.setFillColor(color)
            context.fill(bandRect(rows: visible.rows, columns: run.range, model: model, offset: offset))
        }
        for run in model.sheet.rowStyles.runs(in: visible.rows) {
            guard let color = resolved(run.value, model: model).fill else { continue }
            context.setFillColor(color)
            context.fill(bandRect(rows: run.range, columns: visible.columns, model: model, offset: offset))
        }
    }

    /// Per-cell fills and the agent-change tint.
    private func drawCellFills(
        _ visible: CellRange,
        rows: [Int: [RowEntry]],
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        for row in visible.rows {
            guard let entries = rows[row] else { continue }
            for entry in entries where entry.column >= visible.start.column && entry.column <= visible.end.column {
                let ref = CellRef(row: row, column: entry.column)
                guard !model.merges.isCovered(ref) else { continue }
                guard let color = resolved(entry.cell.styleID, model: model).fill else { continue }
                context.setFillColor(color)
                context.fill(rect(of: ref, model: model, offset: offset))
            }
        }
        drawFlashTints(visible, model: model, context: context, offset: offset)
    }

    private func drawFlashTints(
        _ visible: CellRange,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        guard model.flash.isActive, let affected = model.flash.affectedRange,
              affected.intersects(visible), let overlap = affected.intersection(visible)
        else { return }
        // Bounded by the visible rectangle, so a diff touching a million cells still costs one
        // screenful of tinting.
        for row in overlap.rows {
            for column in overlap.columns {
                let ref = CellRef(row: row, column: column)
                let intensity = model.flash.intensity(of: ref, at: model.flashTime)
                guard intensity > 0.001 else { continue }
                let span = model.merges.merge(containing: ref) ?? CellRange(ref)
                guard span.start == ref || span.isSingleCell else { continue }
                context.setFillColor(
                    cgColor(model.theme.flashTint.withOpacity(intensity * model.theme.flashPeakOpacity))
                )
                context.fill(rect(of: span, model: model, offset: offset))
            }
        }
    }

    // MARK: - Gridlines

    /// One path for every line in the visible rect, stroked as pixel-aligned rectangles.
    ///
    /// Filled rectangles rather than strokes: a stroked hairline straddles the pixel boundary and
    /// comes out two pixels wide and half-grey at 1x, which is exactly the "why does this look
    /// blurry on my external monitor" bug.
    private func drawGridlines(
        _ visible: CellRange,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint,
        clip: CGRect
    ) {
        let geometry = model.geometry
        let thickness = max(1 / backingScale, model.theme.gridlineWidth / backingScale)
        context.setFillColor(palette.gridline)

        var vertical: [CGRect] = []
        vertical.reserveCapacity(visible.columnCount + 1)
        for column in visible.start.column ... (visible.end.column + 1) {
            let x = align(geometry.columns.offset(ofIndex: column) + offset.x)
            guard x >= clip.minX - 1, x <= clip.maxX + 1 else { continue }
            vertical.append(CGRect(x: x, y: clip.minY, width: thickness, height: clip.height))
        }

        var horizontal: [CGRect] = []
        horizontal.reserveCapacity(visible.rowCount + 1)
        for row in visible.start.row ... (visible.end.row + 1) {
            let y = align(geometry.rows.offset(ofIndex: row) + offset.y)
            guard y >= clip.minY - 1, y <= clip.maxY + 1 else { continue }
            horizontal.append(CGRect(x: clip.minX, y: y, width: clip.width, height: thickness))
        }

        context.fill(vertical)
        context.fill(horizontal)
    }

    // MARK: - Merges

    /// Repaints each merged region, which erases the gridlines and banding inside it.
    ///
    /// Excel hides interior gridlines in a merge. Painting over them is both simpler and more
    /// robust than trying to skip the right line segments, and merges are rare enough that the
    /// extra fill costs nothing.
    private func drawMerges(
        _ visible: CellRange,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        guard !model.merges.isEmpty else { return }
        for merge in model.merges.merges(intersecting: visible) {
            let box = rect(of: merge, model: model, offset: offset)
            let cell = model.sheet.cells[merge.start]
            let styleID = model.effectiveStyleID(at: merge.start, cell: cell)
            context.setFillColor(resolved(styleID, model: model).fill ?? palette.canvas)
            context.fill(box)
            let intensity = model.flash.intensity(of: merge.start, at: model.flashTime)
            if intensity > 0.001 {
                context.setFillColor(
                    cgColor(model.theme.flashTint.withOpacity(intensity * model.theme.flashPeakOpacity))
                )
                context.fill(box)
            }
        }
    }

    // MARK: - Borders

    private func drawBorders(
        _ visible: CellRange,
        rows: [Int: [RowEntry]],
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        for row in visible.rows {
            guard let entries = rows[row] else { continue }
            for entry in entries where entry.column >= visible.start.column && entry.column <= visible.end.column {
                let ref = CellRef(row: row, column: entry.column)
                guard !model.merges.isCovered(ref) else { continue }
                let resolvedStyle = resolved(entry.cell.styleID, model: model)
                guard resolvedStyle.hasBorder else { continue }
                let border = resolvedStyle.style.border
                let box = model.merges.merge(containing: ref).map { rect(of: $0, model: model, offset: offset) }
                    ?? rect(of: ref, model: model, offset: offset)
                draw(border, in: box, context: context, model: model)
            }
        }
    }

    private func draw(_ border: BorderStyle, in box: CGRect, context: CGContext, model: GridRenderModel) {
        let palette = model.styles.palette
        func stroke(_ edge: BorderEdge, from start: CGPoint, to end: CGPoint) {
            guard edge.isVisible else { return }
            let width = Self.borderWidth(edge.style)
            context.setStrokeColor(cgColor(edge.color?.resolved(in: palette) ?? model.theme.cellText))
            context.setLineWidth(width)
            if let dash = Self.borderDash(edge.style) {
                context.setLineDash(phase: 0, lengths: dash)
            } else {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            if edge.style == .double {
                // A double border is two lines two points apart, drawn inside the cell edge.
                context.beginPath()
                let inset: CGFloat = 2
                let horizontal = abs(start.y - end.y) < 0.5
                let shift = CGPoint(x: horizontal ? 0 : inset, y: horizontal ? inset : 0)
                context.move(to: CGPoint(x: start.x + shift.x, y: start.y + shift.y))
                context.addLine(to: CGPoint(x: end.x + shift.x, y: end.y + shift.y))
                context.strokePath()
            }
        }

        stroke(border.top, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.maxX, y: box.minY))
        stroke(border.bottom, from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.maxY))
        stroke(border.leading, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.minX, y: box.maxY))
        stroke(border.trailing, from: CGPoint(x: box.maxX, y: box.minY), to: CGPoint(x: box.maxX, y: box.maxY))
        if border.diagonalDown {
            stroke(border.diagonal, from: CGPoint(x: box.minX, y: box.minY), to: CGPoint(x: box.maxX, y: box.maxY))
        }
        if border.diagonalUp {
            stroke(border.diagonal, from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY))
        }
        context.setLineDash(phase: 0, lengths: [])
    }

    static func borderWidth(_ style: BorderEdge.LineStyle) -> CGFloat {
        switch style {
        case .none: 0
        case .hair: 0.5
        case .thin, .dotted, .dashed, .dashDot, .dashDotDot: 1
        case .medium, .mediumDashed, .mediumDashDot, .mediumDashDotDot, .slantDashDot, .double: 2
        case .thick: 3
        }
    }

    static func borderDash(_ style: BorderEdge.LineStyle) -> [CGFloat]? {
        switch style {
        case .dotted: [1, 1]
        case .dashed, .mediumDashed: [3, 2]
        case .dashDot, .mediumDashDot, .slantDashDot: [4, 2, 1, 2]
        case .dashDotDot, .mediumDashDotDot: [4, 2, 1, 2, 1, 2]
        default: nil
        }
    }

    // MARK: - Content

    private func drawContent(
        _ visible: CellRange,
        rows: [Int: [RowEntry]],
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        for row in visible.rows {
            guard let entries = rows[row] else { continue }
            for entry in entries {
                let ref = CellRef(row: row, column: entry.column)
                guard !model.merges.isCovered(ref) else { continue }
                drawCell(entry.cell, at: ref, model: model, context: context, offset: offset)
            }
        }
    }

    private func drawCell(
        _ cell: Cell,
        at ref: CellRef,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        let styleID = model.effectiveStyleID(at: ref, cell: cell)
        let resolvedStyle = resolved(styleID, model: model)
        let style = resolvedStyle.style

        var display: CellDisplay
        if model.options.showsFormulas, let formula = cell.formula {
            display = CellDisplay(text: "=" + formula, horizontal: .left, color: model.theme.cellText)
        } else {
            let key = DisplayKey(
                value: cell.value, style: styleID, isHyperlink: cell.flags.contains(.hyperlink)
            )
            var hit = false
            display = displayCache.value(for: key, hit: &hit) {
                formatter.display(of: cell, style: style, format: resolvedStyle.format)
            }
        }

        let span = model.merges.merge(containing: ref)
        let box = span.map { rect(of: $0, model: model, offset: offset) } ?? rect(of: ref, model: model, offset: offset)
        guard box.width > 1, box.height > 1 else { return }

        if cell.flags.contains(.externalLink) {
            drawExternalLinkMarker(in: box, context: context)
        }
        guard !display.isEmpty else { return }

        let fontKey = resolvedStyle.fontKey
        let padding = model.theme.cellPaddingX * model.geometry.zoom
        let indent = Double(max(0, style.alignment.indent)) * model.theme.indentWidth * model.geometry.zoom
        let available = box.width - 2 * padding - indent

        if style.alignment.wrapText {
            drawWrapped(display, in: box, font: fontKey, padding: padding, indent: indent, context: context)
            return
        }

        var text = display.text
        var shaped = textCache.shaped(text, font: fontKey)

        // `General` sheds decimals until it fits, which is why the same number shows differently
        // in a narrow column and a wide one. Only then does Excel give up and show hashes.
        if display.isGeneralNumber, let value = display.rawNumber, shaped.width > available {
            let digit = textCache.width(of: "0", font: fontKey)
            let budget = digit > 0 ? Int(available / digit) : 0
            text = CellFormatter.generalText(value, budget: max(1, budget))
            shaped = textCache.shaped(text, font: fontKey)
            display.text = text
        }

        var drawRect = box
        if display.isNumeric, shaped.width > available, !display.text.isEmpty {
            // A number that does not fit becomes `####`. It never spills: a number bleeding into
            // the next column would look like the next column's value.
            let hashWidth = textCache.width(of: "#", font: fontKey)
            let count = hashWidth > 0 ? max(1, Int(available / hashWidth)) : 1
            text = String(repeating: "#", count: min(count, 64))
            shaped = textCache.shaped(text, font: fontKey)
            display.text = text
        } else if !display.isNumeric, shaped.width > available {
            // Text spills into empty neighbours, and is cut off — with no ellipsis — against a
            // neighbour that holds something. Both behaviours are load-bearing for real users.
            drawRect = overflowRect(
                from: ref, box: box, needed: shaped.width + 2 * padding + indent,
                display: display, model: model
            )
        }

        // Clipping is not free in Core Graphics, and most cells do not need it: text that fits
        // cannot escape its cell. Clipping only the cells that overflow took a measurable slice
        // off the frame time, and it is the difference between six hundred clip operations a
        // frame and a handful.
        let needsClip = shaped.width + 2 * padding + indent > drawRect.width
            || Self.normalisedRotation(style.alignment.textRotation) != 0
        if needsClip {
            context.saveGState()
            context.clip(to: CGRect(
                x: drawRect.minX, y: box.minY, width: drawRect.width, height: box.height
            ))
        }
        drawLine(
            shaped, display: display, in: box, drawRect: drawRect,
            padding: padding, indent: indent, rotation: style.alignment.textRotation,
            context: context, model: model
        )
        if resolvedStyle.hasDecoration || cell.flags.contains(.staleCache) {
            drawDecorations(
                style: style, shaped: shaped, display: display,
                box: box, drawRect: drawRect, padding: padding, indent: indent,
                isStale: cell.flags.contains(.staleCache), context: context
            )
        }
        if needsClip { context.restoreGState() }
    }

    /// How far text may spill, stopping at the first neighbour that holds something.
    private func overflowRect(
        from ref: CellRef,
        box: CGRect,
        needed: Double,
        display: CellDisplay,
        model: GridRenderModel
    ) -> CGRect {
        let store = model.sheet.cells
        let columns = model.geometry.columns
        var left = box.minX
        var right = box.maxX

        func isBlocking(_ column: Int) -> Bool {
            guard column >= 0, column <= Limits.maxColumn else { return true }
            guard let cell = store[CellRef(row: ref.row, column: column)] else { return false }
            return cell.value != .empty || cell.formula != nil
        }

        let spillsRight = display.horizontal != .right
        let spillsLeft = display.horizontal != .left

        if spillsRight {
            var column = ref.column + 1
            while right - box.minX < needed, column <= Limits.maxColumn, column - ref.column <= 512 {
                if isBlocking(column) { break }
                right += columns.size(ofIndex: column)
                column += 1
            }
        }
        if spillsLeft {
            var column = ref.column - 1
            while right - left < needed, column >= 0, ref.column - column <= 512 {
                if isBlocking(column) { break }
                left -= columns.size(ofIndex: column)
                column -= 1
            }
        }
        return CGRect(x: left, y: box.minY, width: right - left, height: box.height)
    }

    private func drawLine(
        _ shaped: ShapedLine,
        display: CellDisplay,
        in box: CGRect,
        drawRect: CGRect,
        padding: Double,
        indent: Double,
        rotation: Int,
        context: CGContext,
        model: GridRenderModel
    ) {
        let x = horizontalOrigin(
            display: display, shaped: shaped, box: box, drawRect: drawRect, padding: padding, indent: indent
        )
        let y = baseline(for: display.vertical, in: box, shaped: shaped, zoom: model.geometry.zoom)
        context.setFillColor(cgColor(display.color))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        switch Self.normalisedRotation(rotation) {
        case 90:
            context.saveGState()
            context.translateBy(x: box.midX, y: box.maxY - padding)
            context.rotate(by: -.pi / 2)
            context.textPosition = CGPoint(x: 0, y: shaped.ascent / 2 - shaped.descent / 2)
            CTLineDraw(shaped.line, context)
            context.restoreGState()
        case -90:
            context.saveGState()
            context.translateBy(x: box.midX, y: box.minY + padding)
            context.rotate(by: .pi / 2)
            context.textPosition = CGPoint(x: 0, y: shaped.ascent / 2 - shaped.descent / 2)
            CTLineDraw(shaped.line, context)
            context.restoreGState()
        default:
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(shaped.line, context)
        }
    }

    private func drawWrapped(
        _ display: CellDisplay,
        in box: CGRect,
        font: FontKey,
        padding: Double,
        indent: Double,
        context: CGContext
    ) {
        let width = box.width - 2 * padding - indent
        guard width > 2 else { return }
        let lines = wrappedCache.lines(display.text, font: font, width: width)
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.clip(to: box)
        context.setFillColor(cgColor(display.color))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let totalHeight = lines.reduce(0) { $0 + $1.lineHeight }
        var y: Double = switch display.vertical {
        case .top, .justify, .distributed: box.minY + 2
        case .center: box.midY - totalHeight / 2
        case .bottom: box.maxY - totalHeight - 2
        }
        for line in lines {
            y += line.ascent
            let x: Double = switch display.horizontal {
            case .right: box.maxX - padding - line.width
            case .center: box.midX - line.width / 2
            default: box.minX + padding + indent
            }
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line.line, context)
            y += line.descent + line.leading
        }
        context.restoreGState()
    }

    private func drawDecorations(
        style: CellStyle,
        shaped: ShapedLine,
        display: CellDisplay,
        box: CGRect,
        drawRect: CGRect,
        padding: Double,
        indent: Double,
        isStale: Bool,
        context: CGContext
    ) {
        let x = horizontalOrigin(
            display: display, shaped: shaped, box: box, drawRect: drawRect, padding: padding, indent: indent
        )
        let y = baseline(for: display.vertical, in: box, shaped: shaped, zoom: resolvedZoom)

        if style.font.underline != .none {
            let accounting = style.font.underline == .singleAccounting
                || style.font.underline == .doubleAccounting
            let startX = accounting ? box.minX + padding : x
            let endX = accounting ? box.maxX - padding : x + shaped.width
            context.setFillColor(cgColor(display.color))
            context.fill(CGRect(x: startX, y: y + 1.5, width: endX - startX, height: 1 / backingScale))
            if style.font.underline == .double || style.font.underline == .doubleAccounting {
                context.fill(CGRect(x: startX, y: y + 3.5, width: endX - startX, height: 1 / backingScale))
            }
        }
        if style.font.isStrikethrough {
            context.setFillColor(cgColor(display.color))
            context.fill(CGRect(
                x: x, y: y - shaped.ascent / 3, width: shaped.width, height: 1 / backingScale
            ))
        }
        if isStale {
            // The dotted underline is the whole point of `staleCache`: it says "this number is
            // the one the file had, and we could not recompute it". PLAN.md §5.3.
            context.setStrokeColor(palette.staleUnderline)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [1.5, 1.5])
            context.beginPath()
            context.move(to: CGPoint(x: box.minX + padding, y: box.maxY - 1.5))
            context.addLine(to: CGPoint(x: min(box.maxX - padding, x + shaped.width), y: box.maxY - 1.5))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawExternalLinkMarker(in box: CGRect, context: CGContext) {
        let size = min(6.0, box.width / 3, box.height / 2)
        guard size > 1.5 else { return }
        context.setFillColor(palette.externalLink)
        context.beginPath()
        context.move(to: CGPoint(x: box.maxX - size, y: box.minY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        context.addLine(to: CGPoint(x: box.maxX, y: box.minY + size))
        context.closePath()
        context.fillPath()
    }

    // MARK: - Selection

    private func drawSelection(
        _ visible: CellRange,
        model: GridRenderModel,
        context: CGContext,
        offset: CGPoint
    ) {
        let selection = model.selection
        let accent = model.isFocused ? palette.accent : palette.unfocusedSelection
        let activeSpan = model.merges.merge(containing: selection.active) ?? CellRange(selection.active)

        for (index, range) in selection.ranges.enumerated() {
            guard let overlap = range.intersection(visible) else { continue }
            let isActiveRange = index == selection.activeRangeIndex
            context.setFillColor(isActiveRange ? palette.selectionFill : palette.inactiveSelectionFill)

            // The active cell is left unfilled so the caret is visible inside its own selection.
            let box = rect(of: overlap, model: model, offset: offset)
            if isActiveRange, activeSpan.intersects(overlap) {
                let hole = rect(of: activeSpan, model: model, offset: offset)
                for piece in Self.subtract(hole, from: box) {
                    context.fill(piece)
                }
            } else {
                context.fill(box)
            }

            let stroke = isActiveRange ? model.theme.selectionStrokeWidth : 1
            context.setStrokeColor(accent)
            context.setLineWidth(stroke)
            context.stroke(rect(of: range, model: model, offset: offset).insetBy(dx: stroke / 2, dy: stroke / 2))
        }

        if model.options.showsFillHandle, selection.ranges.indices.contains(selection.activeRangeIndex) {
            let range = selection.activeRange
            // The handle straddles the range's bottom-right corner, so it only belongs to a pane
            // that actually contains part of the range. Without this it leaks a few pixels into
            // the pane next door, which is visible as a dot floating in the frozen band.
            guard range.intersects(visible) else { return }
            let box = rect(of: range, model: model, offset: offset)
            let side = model.theme.fillHandleSize
            let handle = CGRect(
                x: box.maxX - side / 2, y: box.maxY - side / 2, width: side, height: side
            )
            context.setFillColor(palette.fillHandleBorder)
            context.fill(handle.insetBy(dx: -1, dy: -1))
            context.setFillColor(accent)
            context.fill(handle)
        }
    }

    /// The parts of `outer` not covered by `inner`, as up to four rectangles.
    static func subtract(_ inner: CGRect, from outer: CGRect) -> [CGRect] {
        let clipped = inner.intersection(outer)
        guard !clipped.isNull, !clipped.isEmpty else { return [outer] }
        var pieces: [CGRect] = []
        if clipped.minY > outer.minY {
            pieces.append(CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: clipped.minY - outer.minY))
        }
        if clipped.maxY < outer.maxY {
            pieces.append(CGRect(x: outer.minX, y: clipped.maxY, width: outer.width, height: outer.maxY - clipped.maxY))
        }
        if clipped.minX > outer.minX {
            pieces.append(CGRect(
                x: outer.minX, y: clipped.minY, width: clipped.minX - outer.minX, height: clipped.height
            ))
        }
        if clipped.maxX < outer.maxX {
            pieces.append(CGRect(
                x: clipped.maxX, y: clipped.minY, width: outer.maxX - clipped.maxX, height: clipped.height
            ))
        }
        return pieces
    }

    // MARK: - Geometry helpers

    private func rect(of ref: CellRef, model: GridRenderModel, offset: CGPoint) -> CGRect {
        model.geometry.sheetRect(of: ref).offsetBy(dx: offset.x, dy: offset.y)
    }

    private func rect(of range: CellRange, model: GridRenderModel, offset: CGPoint) -> CGRect {
        model.geometry.sheetRect(of: range).offsetBy(dx: offset.x, dy: offset.y)
    }

    private func rowRect(
        _ row: Int,
        columns: ClosedRange<Int>,
        model: GridRenderModel,
        offset: CGPoint
    ) -> CGRect {
        bandRect(rows: row ... row, columns: columns, model: model, offset: offset)
    }

    private func bandRect(
        rows: ClosedRange<Int>,
        columns: ClosedRange<Int>,
        model: GridRenderModel,
        offset: CGPoint
    ) -> CGRect {
        rect(of: CellRange(rows: rows, columns: columns), model: model, offset: offset)
    }

    private func horizontalOrigin(
        display: CellDisplay,
        shaped: ShapedLine,
        box: CGRect,
        drawRect: CGRect,
        padding: Double,
        indent: Double
    ) -> Double {
        switch display.horizontal {
        case .right: box.maxX - padding - indent - shaped.width
        case .center: drawRect.midX - shaped.width / 2
        default: box.minX + padding + indent
        }
    }

    private func baseline(
        for vertical: CellAlignment.Vertical,
        in box: CGRect,
        shaped: ShapedLine,
        zoom: Double
    ) -> Double {
        let inset = 2 * zoom
        switch vertical {
        case .top: return box.minY + inset + shaped.ascent
        case .center: return box.midY + (shaped.ascent - shaped.descent) / 2
        case .bottom, .justify, .distributed: return box.maxY - inset - shaped.descent
        }
    }

    /// Snaps a coordinate to a device pixel so hairlines stay hair-thin.
    private func align(_ value: Double) -> Double {
        (value * backingScale).rounded() / backingScale
    }

    /// Excel stores rotation as 0–90 anticlockwise and 91–180 clockwise, plus 255 for stacked
    /// text. We render the three angles that matter and leave the rest horizontal rather than
    /// inventing a layout for vertical CJK stacking.
    static func normalisedRotation(_ raw: Int) -> Int {
        switch raw {
        case 45 ... 90: 90
        case 135 ... 180: -90
        default: 0
        }
    }

    private func refreshPalette(_ model: GridRenderModel) {
        if paletteSource != model.theme {
            palette = ResolvedPalette(model.theme)
            paletteSource = model.theme
            invalidateCaches()
        }
        if formatter.styles != model.styles || formatter.dateSystem != model.dateSystem
            || formatter.theme != model.theme {
            formatter = CellFormatter(styles: model.styles, dateSystem: model.dateSystem, theme: model.theme)
            displayCache.removeAll()
            resolvedStyles.removeAll(keepingCapacity: true)
        }
        if resolvedZoom != model.geometry.zoom {
            resolvedZoom = model.geometry.zoom
            resolvedStyles.removeAll(keepingCapacity: true)
        }
    }

    /// The resolved form of a style, built once and reused for every cell that uses it.
    private func resolved(_ id: StyleID, model: GridRenderModel) -> ResolvedStyle {
        if let existing = resolvedStyles[id] { return existing }
        let style = model.styles[id]
        let fill = style.fill.effectiveColor
            .map { $0.resolved(in: model.theme.stylePalette) }
            .flatMap { $0.alpha > 0 ? $0.cgColor : nil }
        let built = ResolvedStyle(
            style: style,
            format: model.styles.numberFormat(id: style.numberFormatID),
            fontKey: FontKey(
                style: style.font,
                zoom: model.geometry.zoom,
                fallbackFamily: model.theme.bodyFontName,
                fallbackSize: model.theme.defaultFontSize
            ),
            fill: fill,
            hasBorder: style.border.isVisible,
            hasDecoration: style.font.underline != .none || style.font.isStrikethrough
        )
        // A pathological file could name thousands of styles; a cap keeps this honest without
        // needing eviction machinery for a map that is normally a few dozen entries.
        if resolvedStyles.count > 4096 { resolvedStyles.removeAll(keepingCapacity: true) }
        resolvedStyles[id] = built
        return built
    }

    /// The formatter the renderer uses, exposed so headers, tooltips, auto-fit, and
    /// accessibility all report the same text as the pixels do.
    public var displayFormatter: CellFormatter { formatter }

    /// Points the renderer's formatter at a model without drawing anything. Used by auto-fit and
    /// by the accessibility tree.
    public func prepare(for model: GridRenderModel) {
        refreshPalette(model)
    }
}
