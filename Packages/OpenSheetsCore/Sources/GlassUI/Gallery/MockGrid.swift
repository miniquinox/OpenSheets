import SheetModel
import SwiftUI

/// A fake spreadsheet, drawn from a ``GridTheme``.
///
/// **This is not `GridKit`.** A4 owns the real renderer — virtualised, Core Graphics, a million
/// cells at 120 fps. This is thirty rows in a SwiftUI `Canvas`, and it exists for two reasons that
/// are both about the glass rather than about the grid:
///
/// 1. **Glass needs something to refract.** A toolbar photographed over a flat grey rectangle
///    tells you nothing about whether it works; the lens has nothing to bend. Every screenshot in
///    `docs/design/` has this underneath it, and it is why they look like an application.
/// 2. **It is a live proof of ``GridTheme``.** Every colour here comes from the theme value A4
///    consumes, so if a token is wrong — a gridline that vanishes in dark mode, cell text that
///    fails contrast under increase-contrast — it is wrong *on screen, in the gallery*, and not
///    only in a test that says `4.31 < 4.5`.
///
/// The content is a plausible budget rather than lorem ipsum, because column widths, decimal
/// alignment and header emphasis are only judgeable against text that behaves like real data.
public struct MockGrid: View {
    private let theme: GridTheme
    /// The block the agent just changed. Painted with the flash wash, so the "Claude changed this"
    /// language is visible in the same frame as the pill that announces it.
    private let flashedColumn: Int?
    private let selection: CellRange?

    public init(theme: GridTheme, flashedColumn: Int? = 5, selection: CellRange? = nil) {
        self.theme = theme
        self.flashedColumn = flashedColumn
        self.selection = selection
            ?? CellRange(start: CellRef(row: 12, column: 5), end: CellRef(row: 16, column: 5))
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { canvas, size in
            draw(in: &canvas, size: size)
        }
        .background(theme.canvas.color)
        .accessibilityHidden(true)
    }

    // MARK: Content

    private static let columnTitles = ["Line item", "Q1", "Q2", "Q3", "Q4", "Q4 +8%", "Notes"]

    /// Deterministic, so two screenshots of the same state are byte-comparable.
    private static let rows: [(String, [Double], String)] = [
        ("Salaries", [412_000, 418_500, 421_000, 430_000], "headcount flat"),
        ("Contractors", [58_400, 61_200, 47_900, 52_000], ""),
        ("Cloud", [31_250, 33_900, 36_400, 39_100], "usage-based"),
        ("Tooling", [12_800, 12_800, 13_400, 13_400], "annual"),
        ("Travel", [9_600, 21_400, 7_200, 18_800], "offsite in Q4"),
        ("Recruiting", [24_000, 18_500, 9_750, 31_200], ""),
        ("Marketing", [86_200, 91_400, 78_900, 104_600], "campaign"),
        ("Legal", [14_300, 8_900, 22_100, 11_400], ""),
        ("Office", [27_500, 27_500, 27_500, 27_500], "lease"),
        ("Support", [41_900, 44_200, 45_800, 48_300], ""),
        ("Equipment", [18_400, 6_200, 11_900, 26_700], "refresh cycle"),
        ("Training", [7_200, 9_800, 5_400, 12_100], ""),
        ("Insurance", [16_000, 16_000, 16_400, 16_400], ""),
        ("Misc", [4_820, 3_940, 6_110, 5_275], ""),
    ]

    private func draw(in canvas: inout GraphicsContext, size: CGSize) {
        let rowHeight = theme.defaultRowHeight
        let headerHeight = theme.headerRowHeight
        let gutter = theme.headerColumnWidth
        let widths: [CGFloat] = [150, 92, 92, 92, 92, 100, 150]

        func columnX(_ index: Int) -> CGFloat {
            gutter + widths.prefix(index).reduce(0, +)
        }

        let visibleRows = Int(((size.height - headerHeight) / rowHeight).rounded(.up)) + 1

        // Row banding, then the flash wash, then the selection: painted in the order a real
        // renderer would, so overlapping washes composite the way they will in the app.
        if theme.canvasAlternate != theme.canvas {
            for row in 0 ..< visibleRows where row.isMultiple(of: 2) {
                let y = headerHeight + CGFloat(row) * rowHeight
                canvas.fill(
                    Path(CGRect(x: gutter, y: y, width: size.width - gutter, height: rowHeight)),
                    with: .color(theme.canvasAlternate.color)
                )
            }
        }

        if let flashedColumn, flashedColumn < widths.count {
            let x = columnX(flashedColumn)
            let rect = CGRect(
                x: x,
                y: headerHeight,
                width: widths[flashedColumn],
                height: CGFloat(Self.rows.count + 1) * rowHeight
            )
            canvas.fill(Path(rect), with: .color(theme.changeFlashFill.color))
            canvas.fill(
                Path(CGRect(x: x, y: headerHeight, width: 2, height: rect.height)),
                with: .color(theme.changeMarker.color)
            )
        }

        // Gridlines.
        for row in 0 ... visibleRows {
            let y = headerHeight + CGFloat(row) * rowHeight
            canvas.stroke(
                Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                with: .color(theme.gridline.color),
                lineWidth: 1
            )
        }
        for index in 0 ... widths.count {
            let x = columnX(index)
            guard x < size.width else { break }
            canvas.stroke(
                Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                with: .color(theme.gridline.color),
                lineWidth: 1
            )
        }

        // Header band.
        canvas.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: headerHeight)),
            with: .color(theme.headerBackground.color)
        )
        canvas.fill(
            Path(CGRect(x: 0, y: 0, width: gutter, height: size.height)),
            with: .color(theme.headerBackground.color)
        )
        canvas.stroke(
            Path {
                $0.move(to: CGPoint(x: 0, y: headerHeight))
                $0.addLine(to: CGPoint(x: size.width, y: headerHeight))
            },
            with: .color(theme.headerSeparator.color),
            lineWidth: theme.increasedContrast ? 1.5 : 1
        )
        canvas.stroke(
            Path {
                $0.move(to: CGPoint(x: gutter, y: 0))
                $0.addLine(to: CGPoint(x: gutter, y: size.height))
            },
            with: .color(theme.headerSeparator.color),
            lineWidth: theme.increasedContrast ? 1.5 : 1
        )

        // Column letters and row numbers.
        for index in 0 ..< widths.count {
            let x = columnX(index)
            guard x < size.width else { break }
            let isActive = selection.map { index >= $0.start.column && index <= $0.end.column } ?? false
            if isActive {
                canvas.fill(
                    Path(CGRect(x: x, y: 0, width: widths[index], height: headerHeight)),
                    with: .color(theme.headerActiveBackground.color)
                )
            }
            let letter = String(UnicodeScalar(UInt8(65 + index)))
            drawText(
                &canvas,
                letter,
                at: CGPoint(x: x + widths[index] / 2, y: headerHeight / 2),
                anchor: .center,
                font: .system(size: 10, weight: isActive ? .semibold : .regular),
                color: (isActive ? theme.headerActiveInk : theme.headerInk).color
            )
        }
        for row in 0 ..< visibleRows {
            let y = headerHeight + CGFloat(row) * rowHeight
            guard y < size.height else { break }
            let isActive = selection.map { row >= $0.start.row && row <= $0.end.row } ?? false
            if isActive {
                canvas.fill(
                    Path(CGRect(x: 0, y: y, width: gutter, height: rowHeight)),
                    with: .color(theme.headerActiveBackground.color)
                )
            }
            drawText(
                &canvas,
                "\(row + 1)",
                at: CGPoint(x: gutter - theme.cellPadding, y: y + rowHeight / 2),
                anchor: .trailing,
                font: .system(size: 10, weight: isActive ? .semibold : .regular).monospacedDigit(),
                color: (isActive ? theme.headerActiveInk : theme.headerInk).color
            )
        }

        // Cells.
        drawHeaderRow(&canvas, widths: widths, columnX: columnX, headerHeight: headerHeight,
                      rowHeight: rowHeight, size: size)
        drawBodyRows(&canvas, widths: widths, columnX: columnX, headerHeight: headerHeight,
                     rowHeight: rowHeight, size: size)
        drawTotalRow(&canvas, widths: widths, columnX: columnX, headerHeight: headerHeight,
                     rowHeight: rowHeight, size: size)

        // Selection, last, so its stroke is not overdrawn by a gridline.
        if let selection {
            let x = columnX(selection.start.column)
            let width = (selection.start.column ... selection.end.column)
                .reduce(CGFloat.zero) { $0 + widths[$1] }
            let y = headerHeight + CGFloat(selection.start.row) * rowHeight
            let height = CGFloat(selection.end.row - selection.start.row + 1) * rowHeight
            let rect = CGRect(x: x, y: y, width: width, height: height)
            canvas.fill(Path(rect), with: .color(theme.selectionFill.color))
            canvas.stroke(
                Path(rect),
                with: .color(theme.selectionStroke.color),
                lineWidth: theme.selectionStrokeWidth
            )
            let handle = CGRect(
                x: rect.maxX - theme.fillHandleSize / 2,
                y: rect.maxY - theme.fillHandleSize / 2,
                width: theme.fillHandleSize,
                height: theme.fillHandleSize
            )
            canvas.fill(Path(handle), with: .color(theme.fillHandleFill.color))
            canvas.stroke(Path(handle), with: .color(theme.fillHandleStroke.color), lineWidth: 1)
        }
    }

    private func drawHeaderRow(
        _ canvas: inout GraphicsContext,
        widths: [CGFloat],
        columnX: (Int) -> CGFloat,
        headerHeight: CGFloat,
        rowHeight: CGFloat,
        size: CGSize
    ) {
        for (index, title) in Self.columnTitles.enumerated() {
            let x = columnX(index)
            guard x < size.width else { break }
            drawText(
                &canvas,
                title,
                at: CGPoint(x: x + theme.cellPadding, y: headerHeight + rowHeight / 2),
                anchor: .leading,
                font: .system(size: theme.cellFontSize, weight: .semibold),
                color: theme.cellInk.color
            )
        }
    }

    private func drawBodyRows(
        _ canvas: inout GraphicsContext,
        widths: [CGFloat],
        columnX: (Int) -> CGFloat,
        headerHeight: CGFloat,
        rowHeight: CGFloat,
        size: CGSize
    ) {
        for (offset, entry) in Self.rows.enumerated() {
            let y = headerHeight + CGFloat(offset + 1) * rowHeight
            guard y < size.height else { break }
            let centre = y + rowHeight / 2

            drawText(
                &canvas, entry.0,
                at: CGPoint(x: columnX(0) + theme.cellPadding, y: centre),
                anchor: .leading,
                font: .system(size: theme.cellFontSize),
                color: theme.cellInk.color
            )

            for (quarter, value) in entry.1.enumerated() {
                let column = quarter + 1
                let x = columnX(column) + widths[column] - theme.cellPadding
                guard x < size.width else { break }
                drawText(
                    &canvas, currency(value),
                    at: CGPoint(x: x, y: centre),
                    anchor: .trailing,
                    font: .system(size: theme.cellFontSize).monospacedDigit(),
                    color: theme.cellInk.color
                )
            }

            // The agent's column: a formula, so it is drawn in the formula ink.
            let projected = entry.1[3] * 1.08
            let projectedX = columnX(5) + widths[5] - theme.cellPadding
            if projectedX < size.width {
                drawText(
                    &canvas, currency(projected),
                    at: CGPoint(x: projectedX, y: centre),
                    anchor: .trailing,
                    font: .system(size: theme.cellFontSize).monospacedDigit(),
                    color: theme.cellInkFormula.color
                )
            }

            if !entry.2.isEmpty {
                let notesX = columnX(6) + theme.cellPadding
                if notesX < size.width {
                    drawText(
                        &canvas, entry.2,
                        at: CGPoint(x: notesX, y: centre),
                        anchor: .leading,
                        font: .system(size: theme.cellFontSize),
                        color: theme.cellInkSecondary.color
                    )
                }
            }
        }
    }

    private func drawTotalRow(
        _ canvas: inout GraphicsContext,
        widths: [CGFloat],
        columnX: (Int) -> CGFloat,
        headerHeight: CGFloat,
        rowHeight: CGFloat,
        size: CGSize
    ) {
        let row = Self.rows.count + 1
        let y = headerHeight + CGFloat(row) * rowHeight
        guard y < size.height else { return }
        let centre = y + rowHeight / 2

        drawText(
            &canvas, "Total",
            at: CGPoint(x: columnX(0) + theme.cellPadding, y: centre),
            anchor: .leading,
            font: .system(size: theme.cellFontSize, weight: .semibold),
            color: theme.cellInk.color
        )
        for quarter in 0 ..< 4 {
            let column = quarter + 1
            let total = Self.rows.reduce(0.0) { $0 + $1.1[quarter] }
            let x = columnX(column) + widths[column] - theme.cellPadding
            guard x < size.width else { break }
            drawText(
                &canvas, currency(total),
                at: CGPoint(x: x, y: centre),
                anchor: .trailing,
                font: .system(size: theme.cellFontSize, weight: .semibold).monospacedDigit(),
                color: theme.cellInk.color
            )
        }
        // One error cell, because an error is part of what a spreadsheet looks like and the ink
        // for it needs to be judged in situ rather than on a swatch.
        let errorX = columnX(5) + widths[5] - theme.cellPadding
        if errorX < size.width {
            drawText(
                &canvas, "#DIV/0!",
                at: CGPoint(x: errorX, y: centre),
                anchor: .trailing,
                font: .system(size: theme.cellFontSize, weight: .semibold).monospacedDigit(),
                color: theme.cellInkError.color
            )
        }
    }

    private func drawText(
        _ canvas: inout GraphicsContext,
        _ string: String,
        at point: CGPoint,
        anchor: UnitPoint,
        font: Font,
        color: Color
    ) {
        let resolved = canvas.resolve(Text(string).font(font).foregroundStyle(color))
        canvas.draw(resolved, at: point, anchor: anchor)
    }

    private func currency(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }
}
