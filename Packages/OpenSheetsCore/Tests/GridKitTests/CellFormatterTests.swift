import SheetModel
import Testing
@testable import GridKit

@Suite("Cell formatting")
struct CellFormatterTests {
    private func formatter(_ formats: [Int32: NumberFormat] = [:]) -> CellFormatter {
        CellFormatter(styles: StyleTable(styles: [.default], customNumberFormats: formats), theme: .light)
    }

    private func text(_ value: Double, _ code: String) -> String {
        let format = NumberFormat(code)
        let style = CellStyle(numberFormatID: 164)
        return formatter().display(of: Cell(value: .number(value)), style: style, format: format).text
    }

    // MARK: - General

    @Test("General shows integers plainly and trims trailing zeros", arguments: [
        (42.0, "42"), (-42.0, "-42"), (0.0, "0"), (1.5, "1.5"), (0.25, "0.25"),
    ])
    func general(value: Double, expected: String) {
        #expect(CellFormatter.generalText(value, budget: 11) == expected)
    }

    @Test("General sheds decimals to fit the column, then goes scientific")
    func generalFitsTheBudget() {
        // The same number, three column widths. This is the behaviour that makes a spreadsheet
        // feel responsive to a column drag.
        #expect(CellFormatter.generalText(1234.56789, budget: 11) == "1234.56789")
        #expect(CellFormatter.generalText(1234.56789, budget: 7) == "1234.57")
        #expect(CellFormatter.generalText(1234.56789, budget: 4) == "1235")
        #expect(CellFormatter.generalText(123_456_789_012, budget: 11).contains("E+"))
        #expect(CellFormatter.generalText(0.000_000_000_012_3, budget: 11).contains("E-"))
    }

    // MARK: - Fixed point

    @Test("Fixed-point formats round half away from zero, like Excel and unlike printf")
    func rounding() {
        // `printf("%.0f", 0.5)` is "0" — banker's rounding. Excel says 1, and so does a column of
        // prices that someone is going to add up by hand.
        #expect(text(0.5, "0") == "1")
        #expect(text(1.5, "0") == "2")
        #expect(text(2.5, "0") == "3")
        #expect(text(-0.5, "0") == "-1")
        #expect(text(2.345, "0.00") == "2.35")
    }

    @Test("Digit placeholders pad and trim as the code says")
    func placeholders() {
        #expect(text(5, "00000") == "00005")
        #expect(text(0.5, "#.##") == ".5")
        #expect(text(0.5, "0.##") == "0.5")
        #expect(text(1.10, "0.00") == "1.10")
        #expect(text(1.10, "0.##") == "1.1")
    }

    @Test("Thousands separators group from the right")
    func grouping() {
        #expect(text(1_234_567, "#,##0") == "1,234,567")
        #expect(text(999, "#,##0") == "999")
        #expect(text(1000, "#,##0.00") == "1,000.00")
        #expect(CellFormatter.group("1234") == "1,234")
        #expect(CellFormatter.group("12") == "12")
    }

    @Test("Percentages scale before rounding")
    func percentages() {
        // Scaling after rounding gives 1%, which is the classic way to get this wrong.
        #expect(text(0.5, "0%") == "50%")
        #expect(text(0.1234, "0.0%") == "12.3%")
    }

    @Test("Currency keeps its symbol on the right side of the digits")
    func currency() {
        #expect(text(1234.5, "$#,##0.00") == "$1,234.50")
        #expect(text(1234.5, "#,##0.00\" kr\"") == "1,234.50 kr")
    }

    @Test("A negative section supplies its own sign")
    func negativeSection() {
        // One section: the formatter adds the minus. Two: the section owns it, so a bare
        // `#,##0;(#,##0)` must not produce `(-1,234)`.
        #expect(text(-1234, "#,##0") == "-1,234")
        #expect(text(-1234, "#,##0;(#,##0)") == "(1,234)")
        #expect(text(-1234, "#,##0;-#,##0") == "-1,234")
    }

    @Test("A third section formats zero, and an empty one hides it")
    func zeroSection() {
        #expect(text(0, "0.00;-0.00;\"—\"") == "—")
        #expect(text(0, "0.00;-0.00;") == "")
    }

    @Test("Scientific notation honours the mantissa and exponent widths")
    func scientific() {
        #expect(text(12345, "0.00E+00") == "1.23E+04")
        #expect(text(0.00012, "0.00E+00") == "1.20E-04")
    }

    @Test("Fractions pick the closest denominator in range")
    func fractions() {
        #expect(text(2.5, "# ?/?") == "2 1/2")
        #expect(text(2.25, "# ??/??") == "2 1/4")
        let (numerator, denominator) = CellFormatter.bestRational(0.333, maximumDenominator: 9)
        #expect(numerator == 1)
        #expect(denominator == 3)
    }

    // MARK: - Dates

    @Test("Dates render through the 1900 system")
    func dates() {
        // Serial 45,000 is 2023-03-15 in Excel's 1900 system, phantom leap day and all.
        #expect(text(45000, "yyyy-mm-dd") == "2023-03-15")
        #expect(text(45000, "d mmm yyyy") == "15 Mar 2023")
        #expect(text(45000, "dddd") == "Wednesday")
        #expect(text(45000.5, "h:mm AM/PM") == "12:00 PM")
        #expect(text(45000.75, "hh:mm:ss") == "18:00:00")
    }

    @Test("m is minutes after an hour and a month otherwise")
    func monthVersusMinute() {
        #expect(text(45000.5, "h:mm") == "12:00")
        #expect(text(45000, "mm/dd") == "03/15")
    }

    @Test("Elapsed formats count past 24 hours instead of wrapping")
    func elapsed() {
        #expect(text(1.5, "[h]:mm") == "36:00")
        #expect(text(0.125, "[m]") == "180")
    }

    // MARK: - Non-numeric values

    @Test("Alignment defaults follow the value, not the cell")
    func alignmentDefaults() {
        let formatter = formatter()
        let style = CellStyle()
        #expect(
            formatter.display(of: Cell(value: .number(1)), style: style, format: .general).horizontal == .right
        )
        #expect(formatter.display(of: Cell(value: .text("x")), style: style, format: .general).horizontal == .left)
        #expect(
            formatter.display(of: Cell(value: .boolean(true)), style: style, format: .general).horizontal == .center
        )
        #expect(
            formatter.display(of: Cell(value: .error(.divideByZero)), style: style, format: .general)
                .horizontal == .center
        )
    }

    @Test("Booleans and errors render as their tokens")
    func tokens() {
        let formatter = formatter()
        #expect(formatter.display(of: Cell(value: .boolean(true)), styleID: .default).text == "TRUE")
        #expect(formatter.display(of: Cell(value: .boolean(false)), styleID: .default).text == "FALSE")
        #expect(formatter.display(of: Cell(value: .error(.circular)), styleID: .default).text == "#CIRCULAR")
        #expect(formatter.display(of: Cell(value: .error(.divideByZero)), styleID: .default).color == GridTheme
            .light.errorText)
    }

    @Test("A text section substitutes @ and keeps its literals")
    func textSection() {
        let format = NumberFormat("0;-0;0;\"[\"@\"]\"")
        let display = formatter().display(of: Cell(value: .text("hi")), style: CellStyle(), format: format)
        #expect(display.text == "[hi]")
    }

    @Test("The editor shows the formula, not the formatted value")
    func editText() {
        let formatter = formatter()
        #expect(formatter.editText(of: Cell.formula("SUM(A1:A9)", cached: .number(42))) == "=SUM(A1:A9)")
        #expect(formatter.editText(of: Cell(value: .number(1234.5))) == "1234.5")
        #expect(formatter.editText(of: Cell(value: .number(42))) == "42")
        #expect(formatter.editText(of: nil).isEmpty)
    }

    @Test("An empty cell displays nothing")
    func emptyCell() {
        #expect(formatter().display(of: nil, styleID: .default).isEmpty)
        #expect(formatter().display(of: Cell(), styleID: .default).isEmpty)
    }
}
