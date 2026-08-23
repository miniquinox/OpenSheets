import Foundation
import SheetModel

/// Measures how wide a column, or how tall a row, would have to be for its content to fit.
///
/// # Why it is bounded
///
/// "Auto-fit column A" on a sheet with a million rows means measuring a million strings, which
/// takes long enough that the double-click looks like a hang. Excel measures a sample too — it
/// just does not say so. This measures the visible rows plus a bounded sample beyond them and
/// says exactly what it measured, which is the honest version of the same trade.
@MainActor
public enum GridAutoFit {
    /// How many rows a column measurement will look at beyond the visible ones.
    public static let sampleLimit = 2000

    /// The width column `column` needs, in points at 100% zoom.
    public static func width(
        ofColumn column: Int,
        model: GridRenderModel,
        cache: TextLayoutCache,
        rows: ClosedRange<Int>? = nil
    ) -> Double {
        let sheet = model.sheet
        let theme = model.theme
        let formatter = CellFormatter(styles: model.styles, dateSystem: model.dateSystem, theme: theme)
        let searchRange = rows.map { CellRange(rows: $0, columns: column ... column) }
            ?? CellRange.entireColumn(column)

        var widest = 0.0
        var measured = 0
        sheet.cells.forEachCell(in: searchRange) { ref, cell in
            guard measured < sampleLimit else { return }
            measured += 1
            // A cell inside a merge does not decide the column's width — its content belongs to
            // the whole span, and letting it vote makes one merged title stretch column A.
            guard model.merges.merge(containing: ref) == nil else { return }
            let styleID = model.effectiveStyleID(at: ref, cell: cell)
            let style = model.styles[styleID]
            let display = formatter.display(
                of: cell, style: style, format: model.styles.numberFormat(id: style.numberFormatID)
            )
            guard !display.text.isEmpty else { return }
            let key = FontKey(
                style: style.font, zoom: 1,
                fallbackFamily: theme.bodyFontName, fallbackSize: theme.defaultFontSize
            )
            let indent = Double(max(0, style.alignment.indent)) * theme.indentWidth
            widest = max(widest, cache.width(of: display.text, font: key) + indent)
        }

        guard widest > 0 else { return theme.defaultColumnWidth }
        // Excel's own padding either side, plus a point so the last glyph is not clipped.
        return min(widest + 2 * theme.cellPaddingX + 1, 2000)
    }

    /// The height row `row` needs, honouring wrapped cells.
    public static func height(
        ofRow row: Int,
        model: GridRenderModel,
        cache: TextLayoutCache,
        wrapped: WrappedTextCache
    ) -> Double {
        let sheet = model.sheet
        let theme = model.theme
        let formatter = CellFormatter(styles: model.styles, dateSystem: model.dateSystem, theme: theme)
        var tallest = 0.0

        sheet.cells.forEachCell(in: CellRange.entireRow(row)) { ref, cell in
            let styleID = model.effectiveStyleID(at: ref, cell: cell)
            let style = model.styles[styleID]
            let display = formatter.display(
                of: cell, style: style, format: model.styles.numberFormat(id: style.numberFormatID)
            )
            guard !display.text.isEmpty else { return }
            let key = FontKey(
                style: style.font, zoom: 1,
                fallbackFamily: theme.bodyFontName, fallbackSize: theme.defaultFontSize
            )
            if style.alignment.wrapText {
                let width = model.geometry.columns.size(ofIndex: ref.column) - 2 * theme.cellPaddingX
                let lines = wrapped.lines(display.text, font: key, width: max(1, width))
                tallest = max(tallest, lines.reduce(0) { $0 + $1.lineHeight } + 4)
            } else {
                tallest = max(tallest, cache.shaped(display.text, font: key).lineHeight + 6)
            }
        }
        return max(tallest, theme.defaultRowHeight)
    }

    /// Widths for a run of columns, as ``GridEvent/autoFitColumns(columns:suggested:)`` carries.
    public static func widths(
        forColumns columns: ClosedRange<Int>,
        model: GridRenderModel,
        cache: TextLayoutCache,
        rows: ClosedRange<Int>? = nil
    ) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for column in columns {
            result[column] = width(ofColumn: column, model: model, cache: cache, rows: rows)
        }
        return result
    }
}
