import Foundation
import SheetModel
@testable import SheetFormula

/// The workbook every table test evaluates against.
///
/// Deliberately the same shape as `Fixtures/formulas/functions.xlsx`, whose cached values A7
/// cross-checked against a second engine: same `Data` sheet, same columns, same values. That
/// means a row in `functions.tsv` and the corresponding cell in the fixture are testing the
/// same thing from two directions — ours against a hand-written expectation, and the fixture
/// against a real spreadsheet application.
enum TestWorkbook {
    static let dataSheetID = SheetID(1)
    static let calcSheetID = SheetID(2)

    /// The cell the corpus is evaluated in: on `Data`, row 1, well clear of the data itself.
    ///
    /// Row 1 matters. Implicit intersection resolves `=Data!A1:A6` against the formula's own
    /// row, so a formula living on row 1 sees `A1`. Excel behaves the same way, and a corpus
    /// evaluated from row 40 would quietly turn every bare range into `#VALUE!`.
    static let origin = SheetCell(sheet: dataSheetID, ref: CellRef(row: 0, column: 25))

    static func make() -> Workbook {
        var data = Sheet(id: dataSheetID, name: "Data")
        let numbers: [Double] = [10, 20, 30, 40, 50, 60]
        let labels = ["alpha", "beta", "gamma", "alpha", "beta", "gamma"]
        let decimals: [Double] = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5]
        for row in 0 ..< 6 {
            set(&data, row: row, column: 0, .number(numbers[row]))
            set(&data, row: row, column: 1, .text(labels[row]))
            set(&data, row: row, column: 2, .number(decimals[row]))
        }
        set(&data, row: 0, column: 3, .text("  padded  "))
        set(&data, row: 1, column: 3, .text("hello world"))
        set(&data, row: 2, column: 3, .text("mIxEd cAsE"))
        set(&data, row: 0, column: 4, .error(.divideByZero))
        set(&data, row: 1, column: 4, .boolean(true))
        set(&data, row: 2, column: 4, .text(""))
        // E4 is deliberately absent — a blank cell, not an empty string.
        set(&data, row: 4, column: 4, .text("42"))
        set(&data, row: 0, column: 5, .number(45_366))
        set(&data, row: 9, column: 0, .text("x"))
        set(&data, row: 9, column: 1, .text("y"))
        set(&data, row: 9, column: 2, .text("z"))
        set(&data, row: 10, column: 0, .number(1))
        set(&data, row: 10, column: 1, .number(2))
        set(&data, row: 10, column: 2, .number(3))

        let calc = Sheet(id: calcSheetID, name: "Calc")
        return Workbook(sheets: [data, calc])
    }

    static func set(_ sheet: inout Sheet, row: Int, column: Int, _ value: CellValue) {
        try? sheet.cells.setCell(Cell(value: value), at: CellRef(row: row, column: column))
    }

    /// Evaluation options with a fixed clock, so `TODAY()` and `NOW()` are testable.
    /// 45,366.75 is 2024-03-15 at 18:00.
    static let options = EvaluationOptions(dateSystem: .excel1900, now: 45_366.75)
}
