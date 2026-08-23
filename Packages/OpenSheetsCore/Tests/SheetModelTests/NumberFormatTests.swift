@testable import SheetModel
import Testing

@Suite("NumberFormat")
struct NumberFormatTests {
    // MARK: - The codes the brief names

    @Test("0.00 — two fixed decimals")
    func fixedDecimals() throws {
        let format = NumberFormat("0.00")
        #expect(format.kind == .number)
        #expect(format.sections.count == 1)
        let spec = try #require(format.sections[0].number)
        #expect(spec.minimumIntegerDigits == 1)
        #expect(spec.minimumFractionDigits == 2)
        #expect(spec.maximumFractionDigits == 2)
        #expect(!spec.usesThousandsSeparator)
        #expect(spec.scale == 1)
        #expect(spec.currency == nil)
    }

    @Test("#,##0 — grouped integers, no decimals")
    func groupedIntegers() throws {
        let format = NumberFormat("#,##0")
        #expect(format.kind == .number)
        let spec = try #require(format.sections[0].number)
        #expect(spec.usesThousandsSeparator)
        #expect(spec.minimumIntegerDigits == 1)
        #expect(spec.maximumFractionDigits == 0)
        #expect(spec.scale == 1)
    }

    @Test("0% — percentage scales by a hundred")
    func percentage() throws {
        let format = NumberFormat("0%")
        #expect(format.kind == .percentage)
        let spec = try #require(format.sections[0].number)
        #expect(spec.percentCount == 1)
        #expect(spec.scale == 100)
        #expect(spec.suffix == "%")
        #expect(spec.minimumFractionDigits == 0)

        let withDecimals = NumberFormat("0.00%")
        #expect(withDecimals.kind == .percentage)
        #expect(withDecimals.sections[0].number?.minimumFractionDigits == 2)
    }

    @Test("$#,##0.00;[Red]($#,##0.00) — currency with negatives in red")
    func currencyWithRedNegatives() throws {
        let format = NumberFormat("$#,##0.00;[Red]($#,##0.00)")
        #expect(format.kind == .currency)
        #expect(format.sections.count == 2)
        #expect(format.showsNegativeInRed)

        let positive = try #require(format.section(forNumber: 1234.5))
        #expect(positive.color == nil)
        let positiveSpec = try #require(positive.number)
        #expect(positiveSpec.usesThousandsSeparator)
        #expect(positiveSpec.minimumFractionDigits == 2)
        let currency = try #require(positiveSpec.currency)
        #expect(currency.symbol == "$")
        #expect(currency.position == .leading)

        let negative = try #require(format.section(forNumber: -1234.5))
        #expect(negative.color == .red)
        #expect(negative.number?.prefix == "($")
        #expect(negative.number?.suffix == ")")

        // Two sections split at zero: zero uses the positive one.
        #expect(format.section(forNumber: 0)?.color == nil)
    }

    @Test("yyyy-mm-dd — an unambiguous date pattern")
    func isoDatePattern() throws {
        let format = NumberFormat("yyyy-mm-dd")
        #expect(format.kind == .date)
        #expect(format.isDateTime)
        let spec = try #require(format.sections[0].date)
        #expect(spec.hasDate)
        #expect(!spec.hasTime)
        #expect(!spec.usesTwelveHourClock)
        #expect(spec.tokens == [
            .year(digits: 4), .literal("-"), .month(digits: 2), .literal("-"), .day(digits: 2),
        ])
    }

    @Test("@ — the text placeholder")
    func textPlaceholder() {
        let format = NumberFormat("@")
        #expect(format.kind == .text)
        #expect(format.sections.count == 1)
        #expect(format.sections[0].kind == .text)
        #expect(!format.isDateTime)
    }

    // MARK: - Month versus minute

    @Test("m resolves to month or minute by position", arguments: [
        (
            "mm-dd-yy",
            [NumberFormat.DateToken.month(digits: 2), .literal("-"), .day(digits: 2), .literal("-"), .year(digits: 2)]
        ),
        ("h:mm", [.hour(digits: 1), .literal(":"), .minute(digits: 2)]),
        ("mm:ss", [.minute(digits: 2), .literal(":"), .second(digits: 2)]),
        ("h:mm:ss", [.hour(digits: 1), .literal(":"), .minute(digits: 2), .literal(":"), .second(digits: 2)]),
    ])
    func monthVersusMinute(_ code: String, _ expected: [NumberFormat.DateToken]) throws {
        let spec = try #require(NumberFormat(code).sections[0].date)
        #expect(spec.tokens == expected, "for \(code)")
    }

    @Test("m/d/yy h:mm has both a month and a minute in one string")
    func bothInOnePattern() throws {
        let spec = try #require(NumberFormat("m/d/yy h:mm").sections[0].date)
        #expect(spec.tokens == [
            .month(digits: 1), .literal("/"), .day(digits: 1), .literal("/"), .year(digits: 2),
            .literal(" "), .hour(digits: 1), .literal(":"), .minute(digits: 2),
        ])
        #expect(spec.hasDate)
        #expect(spec.hasTime)
        #expect(NumberFormat("m/d/yy h:mm").kind == .dateTime)
    }

    @Test("mmm and longer are always month names, never minutes")
    func longMonthTokensAreNeverMinutes() throws {
        let spec = try #require(NumberFormat("h:mmm").sections[0].date)
        #expect(spec.tokens.contains(.month(digits: 3)))
    }

    // MARK: - Dates and times generally

    @Test("AM/PM makes the clock twelve-hour", arguments: [
        ("h:mm AM/PM", NumberFormat.AmPmStyle.upperLong),
        ("h:mm am/pm", .lowerLong),
        ("h:mm A/P", .upperShort),
        ("h:mm a/p", .lowerShort),
    ])
    func twelveHourClock(_ code: String, _ style: NumberFormat.AmPmStyle) throws {
        let spec = try #require(NumberFormat(code).sections[0].date)
        #expect(spec.usesTwelveHourClock)
        #expect(spec.tokens.contains(.amPm(style)))
    }

    @Test("[h]:mm:ss is elapsed time, not a date")
    func elapsedTime() throws {
        let format = NumberFormat("[h]:mm:ss")
        #expect(format.kind == .time)
        let spec = try #require(format.sections[0].date)
        #expect(spec.hasElapsedComponents)
        #expect(!spec.hasDate)
        #expect(spec.tokens.first == .elapsedHours(digits: 1))
        #expect(spec.tokens.contains(.minute(digits: 2)))
        #expect(spec.tokens.contains(.second(digits: 2)))
    }

    @Test("mmss.0 folds the trailing zeros into fractional seconds")
    func fractionalSeconds() throws {
        let spec = try #require(NumberFormat("mmss.0").sections[0].date)
        #expect(spec.tokens == [.minute(digits: 2), .second(digits: 2), .fractionalSeconds(digits: 1)])
    }

    @Test("month name widths survive", arguments: [1, 2, 3, 4, 5])
    func monthNameWidths(_ width: Int) throws {
        let code = String(repeating: "m", count: width) + "/d/yyyy"
        let spec = try #require(NumberFormat(code).sections[0].date)
        #expect(spec.tokens.first == .month(digits: width))
    }

    // MARK: - Sections

    @Test("sections split on semicolons outside quotes and brackets")
    func sectionSplitting() {
        #expect(NumberFormat("0.00").sections.count == 1)
        #expect(NumberFormat("0.00;(0.00)").sections.count == 2)
        #expect(NumberFormat("0.00;(0.00);\"-\"").sections.count == 3)
        #expect(NumberFormat("0.00;(0.00);\"-\";@").sections.count == 4)
        #expect(NumberFormat("\"a;b\"0").sections.count == 1, "a semicolon in quotes is literal")
        #expect(NumberFormat("[>0]0;0").sections.count == 2)
    }

    @Test("more than four sections is malformed")
    func tooManySections() {
        let format = NumberFormat("0;0;0;0;0")
        #expect(!format.isWellFormed)
        #expect(throws: SheetError.self) { try NumberFormat.validated("0;0;0;0;0") }
    }

    @Test("unterminated quotes and brackets are malformed")
    func unterminatedDelimiters() {
        #expect(!NumberFormat("\"unterminated0.00").isWellFormed)
        #expect(!NumberFormat("[Red0.00").isWellFormed)
        #expect(NumberFormat("[Red]0.00").isWellFormed)
    }

    @Test("a malformed code still parses into something usable")
    func lenientParsing() {
        // One weird format must never stop a workbook from opening.
        let format = NumberFormat("\"oops0.00")
        #expect(!format.isWellFormed)
        #expect(!format.sections.isEmpty)
        #expect(format.formatCode == "\"oops0.00")
    }

    @Test("three sections split positive, negative, and zero")
    func threeWaySplit() throws {
        let format = NumberFormat("[Blue]0.0;[Red]-0.0;[Green]\"zero\"")
        #expect(format.section(forNumber: 5)?.color == .blue)
        #expect(format.section(forNumber: -5)?.color == .red)
        #expect(format.section(forNumber: 0)?.color == .green)
    }

    @Test("explicit conditions take priority over the positional rules")
    func conditionalSections() throws {
        let format = NumberFormat("[>=1000]#,##0,\"k\";[>=0]0;[Red]-0")
        let big = try #require(format.section(forNumber: 5000))
        #expect(big.condition?.comparison == .greaterThanOrEqual)
        #expect(big.condition?.value == 1000)
        #expect(format.section(forNumber: 50)?.condition?.value == 0)
        #expect(format.section(forNumber: -50)?.color == .red)
    }

    @Test("named and indexed colours both parse", arguments: [
        ("[Black]0", NumberFormat.SectionColor.black),
        ("[Blue]0", .blue),
        ("[Cyan]0", .cyan),
        ("[Green]0", .green),
        ("[Magenta]0", .magenta),
        ("[Red]0", .red),
        ("[White]0", .white),
        ("[Yellow]0", .yellow),
        ("[Color12]0", .indexed(12)),
        ("[color 3]0", .indexed(3)),
    ])
    func sectionColours(_ code: String, _ expected: NumberFormat.SectionColor) {
        #expect(NumberFormat(code).sections[0].color == expected)
    }

    @Test("a text section is only returned for text")
    func textSection() {
        let format = NumberFormat("0;-0;0;\"n/a\"@")
        #expect(format.textSection != nil)
        #expect(format.section(forNumber: 5)?.kind == .number)
        #expect(NumberFormat("0.00").textSection == nil)
    }

    // MARK: - Number spec details

    @Test("a trailing comma scales down by a thousand each time")
    func thousandsScaling() throws {
        #expect(try #require(NumberFormat("#,##0,").sections[0].number).scale == 0.001)
        #expect(try #require(NumberFormat("#,##0,,").sections[0].number).scale == 0.000001)
        // Interior commas group, they do not scale.
        #expect(try #require(NumberFormat("#,##0.00").sections[0].number).scale == 1)
    }

    @Test("scientific notation records its exponent digits")
    func scientific() throws {
        let format = NumberFormat("0.00E+00")
        #expect(format.kind == .scientific)
        let spec = try #require(format.sections[0].number)
        #expect(spec.isScientific)
        #expect(spec.exponentDigits == 2)
        #expect(spec.exponentAlwaysSigned)
        #expect(spec.minimumFractionDigits == 2)

        #expect(try #require(NumberFormat("##0.0E-0").sections[0].number).exponentAlwaysSigned == false)
    }

    @Test("fractions record their denominator shape")
    func fractions() throws {
        let simple = NumberFormat("# ?/?")
        #expect(simple.kind == .fraction)
        #expect(try #require(simple.sections[0].number).fraction?.denominatorDigits == 1)

        let wider = NumberFormat("# ??/??")
        #expect(try #require(wider.sections[0].number).fraction?.denominatorDigits == 2)

        let fixed = NumberFormat("# ?/16")
        #expect(try #require(fixed.sections[0].number).fraction?.fixedDenominator == 16)
    }

    @Test("currency symbols are found whether bracketed or literal", arguments: [
        ("$#,##0.00", "$", NumberFormat.CurrencySpec.Position.leading),
        ("#,##0.00 €", "€", .trailing),
        ("[$€-407]#,##0.00", "€", .leading),
        ("£#,##0", "£", .leading),
        ("¥#,##0", "¥", .leading),
    ])
    func currencyDetection(_ code: String, _ symbol: String, _ position: NumberFormat.CurrencySpec.Position) throws {
        let spec = try #require(NumberFormat(code).sections[0].number)
        let currency = try #require(spec.currency, "no currency found in \(code)")
        #expect(currency.symbol == symbol)
        #expect(currency.position == position)
    }

    @Test("[$€-407] records the locale id")
    func localeHint() {
        #expect(NumberFormat("[$€-407]#,##0.00").sections[0].localeID == 0x407)
        #expect(NumberFormat("[$-409]mmm d, yyyy").sections[0].localeID == 0x409)
    }

    @Test("accounting formats are distinguished from plain currency")
    func accountingDetection() {
        let accounting = NumberFormat("_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)")
        #expect(accounting.kind == .accounting)
        #expect(accounting.sections.count == 4)
        #expect(NumberFormat("$#,##0.00").kind == .currency)
    }

    @Test("question-mark fraction positions are counted for alignment")
    func alignedFractionDigits() throws {
        let spec = try #require(NumberFormat("0.??").sections[0].number)
        #expect(spec.alignedFractionDigits == 2)
        #expect(spec.maximumFractionDigits == 2)
        #expect(spec.minimumFractionDigits == 0)
    }

    @Test("escaped and quoted literals become prefix and suffix text")
    func literals() throws {
        let spec = try #require(NumberFormat("\"Total: \"0.00\" units\"").sections[0].number)
        #expect(spec.prefix == "Total: ")
        #expect(spec.suffix == " units")

        let escaped = try #require(NumberFormat("\\$0.00").sections[0].number)
        #expect(escaped.prefix == "$")
    }

    // MARK: - Built-ins

    @Test("the implicit built-in codes are present and parse", arguments: [
        (Int32(0), "General"), (1, "0"), (2, "0.00"), (3, "#,##0"), (4, "#,##0.00"),
        (9, "0%"), (10, "0.00%"), (11, "0.00E+00"), (12, "# ?/?"), (13, "# ??/??"),
        (14, "mm-dd-yy"), (15, "d-mmm-yy"), (16, "d-mmm"), (17, "mmm-yy"),
        (18, "h:mm AM/PM"), (19, "h:mm:ss AM/PM"), (20, "h:mm"), (21, "h:mm:ss"),
        (22, "m/d/yy h:mm"), (45, "mm:ss"), (46, "[h]:mm:ss"), (47, "mmss.0"),
        (48, "##0.0E+0"), (49, "@"),
    ])
    func builtInCodes(_ id: Int32, _ code: String) {
        #expect(NumberFormat.builtInCode(id: id) == code)
        #expect(NumberFormat(code).isWellFormed)
    }

    @Test("the built-in date formats classify as dates")
    func builtInDatesAreDates() {
        for id in Int32(14) ... 22 {
            guard let code = NumberFormat.builtInCode(id: id) else { continue }
            #expect(NumberFormat(code).isDateTime, "built-in \(id) (\(code)) should be a date or time")
        }
    }

    @Test("locale-specific built-in ids are absent rather than guessed")
    func absentBuiltIns() {
        for id in Int32(23) ... 36 {
            #expect(NumberFormat.builtInCode(id: id) == nil, "id \(id) should not be guessed")
        }
        for id in Int32(50) ... 58 {
            #expect(NumberFormat.builtInCode(id: id) == nil, "id \(id) should not be guessed")
        }
    }

    @Test("General is General and nothing else")
    func general() {
        #expect(NumberFormat.general.isGeneral)
        #expect(NumberFormat("General").kind == .general)
        #expect(NumberFormat("general").kind == .general)
        #expect(!NumberFormat("0.00").isGeneral)
        #expect(!NumberFormat.general.isDateTime)
    }
}
