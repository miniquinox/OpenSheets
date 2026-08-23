import Foundation
import GlassUI
import GridKit
import SheetModel

/// The numbers in the floating pill at the bottom of the grid.
///
/// Formatted with the **selection's own number format** when every numeric cell in it agrees, and
/// with General when they do not. That is the rule Excel uses and it is the one that matters: the
/// sum of a currency column has to read as currency, and the sum of a column that mixes currency
/// and percentages has to read as neither rather than as a plausible lie.
public enum SelectionStatistics {
    /// A cap on how much of a selection is walked.
    ///
    /// Selecting column A selects 1,048,576 cells and the pill must not spend a frame on it. The
    /// store is sparse, so this only ever bites on a genuinely enormous block, and the pill says
    /// nothing rather than something wrong — there is no "approximately" in a spreadsheet.
    public static let cellBudget = 500_000

    public static func compute(
        selection: GridSelection,
        sheet: Sheet,
        styles: StyleTable,
        dateSystem: DateSystem,
        visible: [SelectionStat] = SelectionStat.defaultVisible
    ) -> SelectionStats {
        var count = 0
        var numericCount = 0
        var sum = 0.0
        var minimum = Double.infinity
        var maximum = -Double.infinity
        var formatIDs: Set<Int32> = []
        var walked = 0

        for range in selection.ranges {
            guard walked < cellBudget else { break }
            sheet.cells.forEachCell(in: range) { ref, cell in
                walked += 1
                guard !cell.isBlank else { return }
                count += 1
                guard let value = cell.value.number else { return }
                numericCount += 1
                sum += value
                minimum = Swift.min(minimum, value)
                maximum = Swift.max(maximum, value)
                let styleID = cell.styleID == .default ? sheet.effectiveStyleID(at: ref) : cell.styleID
                formatIDs.insert(styles[styleID].numberFormatID)
            }
        }

        let format = formatIDs.count == 1
            ? styles.numberFormat(id: formatIDs.first ?? 0)
            : NumberFormat.general
        let formatter = CellFormatter(styles: styles, dateSystem: dateSystem, theme: .light)

        func render(_ value: Double) -> String {
            formatter.display(
                of: Cell(value: .number(value)), style: .init(), format: format
            ).text
        }

        var values: [SelectionStat: String] = [:]
        values[.count] = count.formatted()
        if numericCount > 0 {
            values[.numericCount] = numericCount.formatted()
            values[.sum] = render(sum)
            values[.average] = render(sum / Double(numericCount))
            values[.minimum] = render(minimum)
            values[.maximum] = render(maximum)
        }

        return SelectionStats(
            rangeLabel: label(for: selection),
            values: values,
            visible: visible
        )
    }

    /// `B2:B41`, or `41R × 3C` for a block, or `A1` for one cell.
    ///
    /// Excel switches to the R×C form while you are dragging because the address of a rectangle
    /// you are still drawing is less useful than its size. We switch on shape rather than on drag
    /// state, which is the same information without the mode.
    public static func label(for selection: GridSelection) -> String {
        if selection.ranges.count > 1 {
            return "\(selection.ranges.count) ranges · \(selection.cellCount.formatted()) cells"
        }
        let range = selection.activeRange
        if range.isSingleCell { return range.start.a1String }
        if range.rowCount > 1, range.columnCount > 1 {
            return "\(range.rowCount)R × \(range.columnCount)C"
        }
        return range.a1String
    }
}
