import Foundation
import SheetModel

/// Synthetic workbooks, so the grid can be developed, previewed and profiled with no file reader.
///
/// A1 owns xlsx parsing and lands in the same wave as this component, so waiting for it would
/// have meant writing the renderer blind. It is also the better harness even once A1 exists: the
/// shape is exactly reproducible, the size is a parameter, and a benchmark that opens a file
/// measures the file reader as much as the renderer.
///
/// ``millionCells()`` is the one the acceptance criteria are written against.
public enum GridDemoWorkbook {
    /// A workbook whose sheet holds `rows × columns` populated cells.
    ///
    /// The content is deliberately varied, because a grid that only ever draws short integers is
    /// a grid whose text cache always hits and whose overflow rules are never exercised. There
    /// are long strings that spill, strings blocked by a neighbour, numbers too wide for their
    /// column, dates, booleans, errors, formulas with cached values, and a stale-cache cell.
    ///
    /// - Parameters:
    ///   - rows: populated rows.
    ///   - columns: populated columns.
    ///   - seed: fixes the pseudo-random content, so two runs draw the same pixels.
    ///   - frozen: rows and columns to freeze.
    ///   - merges: whether to include merged regions, one of which straddles the frozen boundary.
    public static func make(
        rows: Int = 20_000,
        columns: Int = 50,
        seed: UInt64 = 0x5EED_1234_ABCD_0001,
        frozen: (rows: Int, columns: Int) = (0, 0),
        merges: Bool = false
    ) -> Workbook {
        var styles = StyleTable()
        let header = styles.intern(CellStyle(
            numberFormatID: 0,
            font: FontStyle(size: 12, isBold: true, color: .rgb(RGBAColor(red: 20, green: 20, blue: 24))),
            fill: .solid(.rgb(RGBAColor(red: 236, green: 238, blue: 242))),
            alignment: CellAlignment(horizontal: .center)
        ))
        let currency = styles.intern(CellStyle(numberFormatID: 44))
        let percent = styles.intern(CellStyle(numberFormatID: 10))
        let date = styles.intern(CellStyle(numberFormatID: 14))
        let plain = StyleID.default

        var store = CellStore()
        store.reserveCapacity(rows: rows)
        var random = SplitMix64(seed: seed)

        for column in 0 ..< columns {
            try? store.setCell(
                Cell(value: .text(headerName(column)), styleID: header),
                at: CellRef(row: 0, column: column)
            )
        }

        for row in 1 ..< rows {
            for column in 0 ..< columns {
                let ref = CellRef(row: row, column: column)
                let cell = syntheticCell(
                    row: row,
                    column: column,
                    random: &random,
                    styles: (plain, currency, percent, date)
                )
                try? store.setCell(cell, at: ref)
            }
        }

        var sheet = Sheet(
            id: SheetID(1),
            name: "Synthetic",
            cells: store,
            frozen: FrozenPanes(frozenRows: frozen.rows, frozenColumns: frozen.columns)
        )
        // A handful of customised sizes, so the axis metrics have real bands to binary-search
        // rather than one uniform run — which is the case that would hide a bug.
        sheet.columnWidths.setValue(150, in: 1 ... 1)
        sheet.columnWidths.setValue(52, in: 4 ... 6)
        sheet.rowHeights.setValue(34, in: 0 ... 0)
        sheet.rowHeights.setValue(18, in: 1000 ... 1200)
        sheet.hiddenRows.setValue(true, in: 500 ... 503)
        sheet.hiddenColumns.setValue(true, in: 9 ... 9)

        if merges, columns >= 6, rows >= 12 {
            // `nonOverlapping` matters: `Sheet.validate()` refuses overlapping merges, and the
            // third of these deliberately reaches across the frozen boundary.
            sheet.merges = Self.nonOverlapping([
                CellRange(rows: 2 ... 3, columns: 1 ... 3),
                CellRange(rows: 6 ... 6, columns: 0 ... 4),
                CellRange(rows: 8 ... 9, columns: 1 ... 4),
            ])
        }

        var workbook = Workbook(sheets: [sheet], styles: styles)
        workbook.meta.application = "GridKit demo harness"
        return workbook
    }

    /// 1,000,000 populated cells: 20,000 rows × 50 columns.
    ///
    /// The size the acceptance criteria name. Building it takes a moment; hold onto the result
    /// rather than calling this in a loop.
    public static func millionCells(frozen: (rows: Int, columns: Int) = (0, 0), merges: Bool = false) -> Workbook {
        make(rows: 20_000, columns: 50, frozen: frozen, merges: merges)
    }

    /// A small sheet for snapshot tests: frozen panes, merges, and a merge across the boundary.
    public static func frozenAndMerged() -> Workbook {
        var workbook = make(rows: 40, columns: 12, frozen: (2, 2), merges: false)
        var sheet = workbook.sheets[0]
        sheet.merges = [
            // Entirely inside the frozen corner.
            CellRange(rows: 0 ... 1, columns: 0 ... 1),
            // Straddles the vertical frozen boundary: two columns frozen, four columns wide.
            CellRange(rows: 3 ... 3, columns: 1 ... 4),
            // Straddles the horizontal one.
            CellRange(rows: 1 ... 4, columns: 6 ... 7),
        ]
        try? store(&sheet, text: "Straddles the frozen boundary", at: CellRef(row: 3, column: 1))
        try? store(&sheet, text: "Tall merge", at: CellRef(row: 1, column: 6))
        workbook.update(sheet)
        return workbook
    }

    private static func store(_ sheet: inout Sheet, text: String, at ref: CellRef) throws(SheetError) {
        try sheet.cells.setCell(Cell(value: .text(text)), at: ref)
    }

    /// Drops any merge that overlaps an earlier one, which `Sheet.validate()` requires.
    static func nonOverlapping(_ merges: [CellRange]) -> [CellRange] {
        var kept: [CellRange] = []
        for merge in merges where !kept.contains(where: { $0.intersects(merge) }) {
            kept.append(merge)
        }
        return kept
    }

    private static func headerName(_ column: Int) -> String {
        let names = [
            "Region", "Description", "Units", "Unit price", "Q1", "Q2", "Q3", "Q4",
            "Margin", "Hidden", "Opened", "Status",
        ]
        return names.indices.contains(column) ? names[column] : "Metric \(column + 1)"
    }

    private static func syntheticCell(
        row: Int,
        column: Int,
        random: inout SplitMix64,
        styles: (plain: StyleID, currency: StyleID, percent: StyleID, date: StyleID)
    ) -> Cell {
        let draw = random.next() % 100
        switch column % 12 {
        case 0:
            return Cell(value: .text(["North", "South", "East", "West"][Int(draw) % 4]), styleID: styles.plain)
        case 1:
            // Long enough to spill into an empty neighbour, some of the time.
            return draw < 20
                ? Cell(value: .text("A description long enough to overflow its column"), styleID: styles.plain)
                : Cell(value: .text("Item \(row)"), styleID: styles.plain)
        case 2:
            return Cell(value: .number(Double(draw)), styleID: styles.plain)
        case 3:
            return Cell(value: .number(Double(draw) * 1.37 + 0.5), styleID: styles.currency)
        case 8:
            return Cell(value: .number(Double(draw) / 100), styleID: styles.percent)
        case 10:
            return Cell(value: .number(Double(44_000 + row % 900)), styleID: styles.date)
        case 11:
            switch draw % 5 {
            case 0: return Cell(value: .boolean(draw < 50), styleID: styles.plain)
            case 1: return Cell(value: .error(.notAvailable), styleID: styles.plain)
            case 2: return Cell(
                    value: .number(Double(draw)),
                    formula: "SUM(C\(row + 1):D\(row + 1))",
                    styleID: styles.plain,
                    flags: .staleCache
                )
            default: return Cell(value: .text("OK"), styleID: styles.plain)
            }
        default:
            // Wide numbers, so `####` gets exercised in the narrow columns.
            return Cell(value: .number(Double(draw) * 987_654.321), styleID: styles.plain)
        }
    }
}

/// A tiny deterministic generator, so a synthetic workbook is byte-identical run to run.
///
/// `SystemRandomNumberGenerator` is not reproducible, and a benchmark whose input changes between
/// runs measures nothing.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
