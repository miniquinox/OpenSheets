import AppKit
import CoreGraphics
import CoreText
import Foundation
import SheetModel

/// Draws the column letters, the row numbers, and the corner.
///
/// Headers are their own renderer because they are their own *views* — floating subviews of the
/// scroll view, so they pin while the canvas scrolls under them. They share the geometry and the
/// text cache with the grid, and nothing else.
///
/// Each header draws in two segments when the sheet has frozen panes: the frozen band, pinned at
/// the origin, and the scrolling band beyond it. Same maths as the panes, so a frozen column's
/// letter never slides away from the column it names.
@MainActor
public final class GridHeaderRenderer {
    private let textCache: TextLayoutCache
    private var palette: ResolvedPalette
    private var paletteSource: GridTheme

    /// Display scale, so separators stay one device pixel.
    public var backingScale: Double = 2

    public init(theme: GridTheme = .light, textCache: TextLayoutCache? = nil) {
        palette = ResolvedPalette(theme)
        paletteSource = theme
        self.textCache = textCache ?? TextLayoutCache(capacity: 512)
    }

    private func refresh(_ theme: GridTheme) {
        guard paletteSource != theme else { return }
        palette = ResolvedPalette(theme)
        paletteSource = theme
    }

    /// The width the row header needs for the largest row number currently on screen.
    ///
    /// Row 1,048,576 is seven characters; a header sized for "10" and never re-measured is the
    /// reason some grids show `104857…` at the bottom of a big sheet.
    public func rowHeaderWidth(forLastRow row: Int, theme: GridTheme, zoom: Double) -> Double {
        let key = FontKey(
            family: theme.bodyFontName,
            size: theme.headerFontSize * zoom,
            isBold: false,
            isItalic: false
        )
        let sample = String(max(1, row + 1))
        return max(theme.headerWidth, textCache.width(of: sample, font: key) + 14)
    }

    // MARK: - Column header

    /// Draws the column letters.
    ///
    /// - Parameters:
    ///   - viewRect: the header strip's own bounds.
    ///   - scrollOrigin: the document view's scroll origin, in document space.
    public func drawColumnHeader(
        into context: CGContext,
        viewRect: CGRect,
        scrollOrigin: CGPoint,
        model: GridRenderModel
    ) {
        refresh(model.theme)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewRect)
        context.setFillColor(palette.headerBackground)
        context.fill(viewRect)

        let geometry = model.geometry
        let frozenWidth = geometry.frozenWidth

        if geometry.frozenColumns > 0 {
            drawColumnSegment(
                into: context,
                clip: CGRect(x: viewRect.minX, y: viewRect.minY, width: frozenWidth, height: viewRect.height),
                columnLimit: 0 ... (geometry.frozenColumns - 1),
                offsetX: viewRect.minX,
                model: model
            )
        }
        let scrollingStart = viewRect.minX + frozenWidth
        drawColumnSegment(
            into: context,
            clip: CGRect(
                x: scrollingStart, y: viewRect.minY,
                width: max(0, viewRect.maxX - scrollingStart), height: viewRect.height
            ),
            columnLimit: geometry.frozenColumns ... (geometry.columns.count - 1),
            offsetX: viewRect.minX - scrollOrigin.x,
            model: model
        )

        context.setFillColor(palette.headerSeparator)
        context.fill(CGRect(
            x: viewRect.minX, y: viewRect.maxY - 1 / backingScale,
            width: viewRect.width, height: 1 / backingScale
        ))
    }

    private func drawColumnSegment(
        into context: CGContext,
        clip: CGRect,
        columnLimit: ClosedRange<Int>,
        offsetX: Double,
        model: GridRenderModel
    ) {
        guard clip.width > 0.5 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: clip)

        let geometry = model.geometry
        let first = max(columnLimit.lowerBound, geometry.columns.index(atOffset: clip.minX - offsetX))
        let last = min(columnLimit.upperBound, geometry.columns.index(atOffset: clip.maxX - offsetX))
        guard first <= last else { return }

        let font = FontKey(
            family: model.theme.bodyFontName,
            size: model.theme.headerFontSize * geometry.zoom,
            isBold: false,
            isItalic: false
        )
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for column in first ... last {
            let width = geometry.columns.size(ofIndex: column)
            guard width > 0 else { continue }
            let x = geometry.columns.offset(ofIndex: column) + offsetX
            let box = CGRect(x: x, y: clip.minY, width: width, height: clip.height)

            let isActive = model.selection.active.column == column
                || model.selection.coversEntireColumn(column)
            let isSelected = model.selection.intersectsColumn(column)
            if isActive {
                context.setFillColor(palette.headerActive)
                context.fill(box)
            } else if isSelected {
                context.setFillColor(palette.headerSelected)
                context.fill(box)
            }

            context.setFillColor(palette.headerSeparator)
            context.fill(CGRect(
                x: box.maxX - 1 / backingScale, y: box.minY + 3,
                width: 1 / backingScale, height: box.height - 6
            ))

            let label = CellRef.columnLetters(column)
            let shaped = textCache.shaped(label, font: font)
            guard shaped.width < box.width - 2 else { continue }
            context.setFillColor(
                isActive ? palette.headerActiveText : (isSelected ? palette.headerSelectedText : palette.headerText)
            )
            context.textPosition = CGPoint(
                x: box.midX - shaped.width / 2,
                y: box.midY + (shaped.ascent - shaped.descent) / 2
            )
            CTLineDraw(shaped.line, context)
        }
    }

    // MARK: - Row header

    /// Draws the row numbers.
    public func drawRowHeader(
        into context: CGContext,
        viewRect: CGRect,
        scrollOrigin: CGPoint,
        model: GridRenderModel
    ) {
        refresh(model.theme)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewRect)
        context.setFillColor(palette.headerBackground)
        context.fill(viewRect)

        let geometry = model.geometry
        let frozenHeight = geometry.frozenHeight

        if geometry.frozenRows > 0 {
            drawRowSegment(
                into: context,
                clip: CGRect(x: viewRect.minX, y: viewRect.minY, width: viewRect.width, height: frozenHeight),
                rowLimit: 0 ... (geometry.frozenRows - 1),
                offsetY: viewRect.minY,
                model: model
            )
        }
        let scrollingStart = viewRect.minY + frozenHeight
        drawRowSegment(
            into: context,
            clip: CGRect(
                x: viewRect.minX, y: scrollingStart,
                width: viewRect.width, height: max(0, viewRect.maxY - scrollingStart)
            ),
            rowLimit: geometry.frozenRows ... (geometry.rows.count - 1),
            offsetY: viewRect.minY - scrollOrigin.y,
            model: model
        )

        context.setFillColor(palette.headerSeparator)
        context.fill(CGRect(
            x: viewRect.maxX - 1 / backingScale, y: viewRect.minY,
            width: 1 / backingScale, height: viewRect.height
        ))
    }

    private func drawRowSegment(
        into context: CGContext,
        clip: CGRect,
        rowLimit: ClosedRange<Int>,
        offsetY: Double,
        model: GridRenderModel
    ) {
        guard clip.height > 0.5 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: clip)

        let geometry = model.geometry
        let first = max(rowLimit.lowerBound, geometry.rows.index(atOffset: clip.minY - offsetY))
        let last = min(rowLimit.upperBound, geometry.rows.index(atOffset: clip.maxY - offsetY))
        guard first <= last else { return }

        let font = FontKey(
            family: model.theme.bodyFontName,
            size: model.theme.headerFontSize * geometry.zoom,
            isBold: false,
            isItalic: false
        )
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        for row in first ... last {
            let height = geometry.rows.size(ofIndex: row)
            guard height > 0 else { continue }
            let y = geometry.rows.offset(ofIndex: row) + offsetY
            let box = CGRect(x: clip.minX, y: y, width: clip.width, height: height)

            let isActive = model.selection.active.row == row || model.selection.coversEntireRow(row)
            let isSelected = model.selection.intersectsRow(row)
            if isActive {
                context.setFillColor(palette.headerActive)
                context.fill(box)
            } else if isSelected {
                context.setFillColor(palette.headerSelected)
                context.fill(box)
            }

            context.setFillColor(palette.headerSeparator)
            context.fill(CGRect(
                x: box.minX + 3, y: box.maxY - 1 / backingScale,
                width: box.width - 6, height: 1 / backingScale
            ))

            // Row numbers are the one place tabular figures matter most: a column of right-aligned
            // numbers that jitters as you scroll is unreadable, and `FontResolver` guarantees it.
            let shaped = textCache.shaped(String(row + 1), font: font)
            guard shaped.width < box.width - 4, shaped.lineHeight < box.height + 4 else { continue }
            context.setFillColor(
                isActive ? palette.headerActiveText : (isSelected ? palette.headerSelectedText : palette.headerText)
            )
            context.textPosition = CGPoint(
                x: box.maxX - 6 - shaped.width,
                y: box.midY + (shaped.ascent - shaped.descent) / 2
            )
            CTLineDraw(shaped.line, context)
        }
    }

    // MARK: - Corner

    /// The square where the two headers meet — click it to select the whole sheet.
    public func drawCorner(into context: CGContext, viewRect: CGRect, model: GridRenderModel) {
        refresh(model.theme)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewRect)
        context.setFillColor(palette.headerBackground)
        context.fill(viewRect)
        context.setFillColor(palette.headerSeparator)
        context.fill(CGRect(
            x: viewRect.maxX - 1 / backingScale, y: viewRect.minY,
            width: 1 / backingScale, height: viewRect.height
        ))
        context.fill(CGRect(
            x: viewRect.minX, y: viewRect.maxY - 1 / backingScale,
            width: viewRect.width, height: 1 / backingScale
        ))
        // A small triangle in the corner, the way Excel marks "select all".
        let side = min(7.0, viewRect.width / 2.5, viewRect.height / 2.5)
        guard side > 2 else { return }
        context.setFillColor(palette.headerText)
        context.beginPath()
        context.move(to: CGPoint(x: viewRect.maxX - 4, y: viewRect.maxY - 4))
        context.addLine(to: CGPoint(x: viewRect.maxX - 4 - side, y: viewRect.maxY - 4))
        context.addLine(to: CGPoint(x: viewRect.maxX - 4, y: viewRect.maxY - 4 - side))
        context.closePath()
        context.fillPath()
    }

    // MARK: - Frozen dividers

    /// The 1pt line between a frozen pane and a scrolling one, with a soft shadow cast toward
    /// the side that moves — which is what makes the frozen band read as being on top.
    public func drawFrozenDividers(
        into context: CGContext,
        viewRect: CGRect,
        model: GridRenderModel
    ) {
        refresh(model.theme)
        let geometry = model.geometry
        let width = model.theme.frozenDividerWidth
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewRect)

        if geometry.frozenColumns > 0 {
            let x = viewRect.minX + geometry.frozenWidth
            for step in 0 ..< 4 {
                let alpha = 0.9 - Double(step) * 0.22
                context.setFillColor(model.theme.frozenDividerShadow.withOpacity(
                    Double(model.theme.frozenDividerShadow.alpha) / 255 * alpha
                ).cgColor)
                context.fill(CGRect(x: x + width + Double(step), y: viewRect.minY, width: 1, height: viewRect.height))
            }
            context.setFillColor(palette.frozenDivider)
            context.fill(CGRect(x: x, y: viewRect.minY, width: width, height: viewRect.height))
        }
        if geometry.frozenRows > 0 {
            let y = viewRect.minY + geometry.frozenHeight
            for step in 0 ..< 4 {
                let alpha = 0.9 - Double(step) * 0.22
                context.setFillColor(model.theme.frozenDividerShadow.withOpacity(
                    Double(model.theme.frozenDividerShadow.alpha) / 255 * alpha
                ).cgColor)
                context.fill(CGRect(x: viewRect.minX, y: y + width + Double(step), width: viewRect.width, height: 1))
            }
            context.setFillColor(palette.frozenDivider)
            context.fill(CGRect(x: viewRect.minX, y: y, width: viewRect.width, height: width))
        }
    }
}
