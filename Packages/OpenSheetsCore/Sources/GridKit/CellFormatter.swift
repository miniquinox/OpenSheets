import Foundation
import SheetModel

/// Turns a ``CellValue`` into the characters Excel would show for it.
///
/// # Why this lives in GridKit
///
/// `SheetModel` parses a format code into ``NumberFormat/Section``s but deliberately stops
/// short of rendering — `CellValue.description` says so in as many words. Rendering needs a
/// column width (`General` sheds decimals to fit, and a number that will not fit becomes
/// `####`), so it belongs next to the thing that knows the width.
///
/// # What it is not
///
/// It is not a locale-aware formatter. `[$-409]` round-trips and is readable, but no locale
/// substitution happens: Excel's locale rules are deep, and a half-implemented version of them
/// produces dates that are confidently wrong rather than obviously unformatted.
public struct CellFormatter: Sendable {
    /// The workbook's styles — the source of both the ``CellStyle`` and the ``NumberFormat``.
    public var styles: StyleTable
    /// 1900 or 1904. Wrong by four years and a day if you guess.
    public var dateSystem: DateSystem
    /// Supplies the automatic text colour and the error colour.
    public var theme: GridTheme

    public init(styles: StyleTable, dateSystem: DateSystem = .excel1900, theme: GridTheme = .light) {
        self.styles = styles
        self.dateSystem = dateSystem
        self.theme = theme
    }

    /// The palette every ``StyleColor`` in this workbook resolves against: the workbook's own
    /// theme for the colours it chose, this grid's appearance for the ones that mean "text"
    /// and "background".
    public var stylePalette: ColorPalette { theme.stylePalette(basedOn: styles.palette) }

    // MARK: - Entry point

    /// How the cell at a style should be drawn.
    public func display(of cell: Cell?, styleID: StyleID) -> CellDisplay {
        let style = styles[styleID]
        let format = styles.numberFormat(id: style.numberFormatID)
        return display(of: cell, style: style, format: format)
    }

    /// How the cell should be drawn, given a style and format already looked up.
    ///
    /// The renderer resolves those once per column band rather than once per cell, which is why
    /// this overload exists.
    public func display(of cell: Cell?, style: CellStyle, format: NumberFormat) -> CellDisplay {
        let palette = stylePalette
        let styleColor = style.font.color.resolved(in: palette)
        let alignment = style.alignment

        guard let cell else {
            return CellDisplay(text: "", horizontal: .left, vertical: alignment.vertical, color: styleColor)
        }

        switch cell.value {
        case .empty:
            return CellDisplay(text: "", horizontal: .left, vertical: alignment.vertical, color: styleColor)

        case let .error(error):
            return CellDisplay(
                text: error.rawValue,
                horizontal: resolve(alignment.horizontal, default: .center),
                vertical: alignment.vertical,
                color: theme.errorText
            )

        case let .boolean(flag):
            return CellDisplay(
                text: flag ? "TRUE" : "FALSE",
                horizontal: resolve(alignment.horizontal, default: .center),
                vertical: alignment.vertical,
                color: styleColor
            )

        case let .text(text):
            let rendered = format.textSection.map { applyTextSection($0, to: text) } ?? text
            return CellDisplay(
                text: rendered,
                horizontal: resolve(alignment.horizontal, default: .left),
                vertical: alignment.vertical,
                color: cell.flags.contains(.hyperlink) ? theme.hyperlinkText : styleColor,
                fillCharacter: format.textSection?.number?.fillCharacter?.first
            )

        case let .number(value):
            return numberDisplay(value, style: style, format: format, fallbackColor: styleColor, palette: palette)
        }
    }

    /// What the formula bar and the in-cell editor show: the formula with its `=`, or the value
    /// at full precision.
    ///
    /// Never the *formatted* text. Editing a cell that shows `£1,234` and getting `£1,234` in
    /// the editor is how a currency column turns into a text column.
    public func editText(of cell: Cell?) -> String {
        guard let cell else { return "" }
        if let formula = cell.formula { return "=" + formula }
        switch cell.value {
        case .empty: return ""
        case let .number(value): return Self.roundTripText(value)
        case let .text(text): return text
        case let .boolean(flag): return flag ? "TRUE" : "FALSE"
        case let .error(error): return error.rawValue
        }
    }

    // MARK: - Numbers

    private func numberDisplay(
        _ value: Double,
        style: CellStyle,
        format: NumberFormat,
        fallbackColor: RGBAColor,
        palette: ColorPalette
    ) -> CellDisplay {
        let horizontal = resolve(style.alignment.horizontal, default: .right)

        guard let section = format.section(forNumber: value), section.kind != .general else {
            return CellDisplay(
                text: Self.generalText(value, budget: Self.defaultGeneralBudget),
                horizontal: horizontal,
                vertical: style.alignment.vertical,
                color: fallbackColor,
                isNumeric: true,
                isGeneralNumber: true,
                rawNumber: value
            )
        }

        let color = section.color?.resolved(in: palette) ?? fallbackColor

        switch section.kind {
        case .blank:
            // `0.00;;` renders zero as nothing at all. An empty section is a real instruction.
            return CellDisplay(text: "", horizontal: horizontal, vertical: style.alignment.vertical, color: color)

        case .text:
            return CellDisplay(
                text: section.literalText,
                horizontal: horizontal,
                vertical: style.alignment.vertical,
                color: color
            )

        case .date:
            guard let spec = section.date else { break }
            return CellDisplay(
                text: dateText(value, spec: spec),
                horizontal: horizontal,
                vertical: style.alignment.vertical,
                color: color,
                isNumeric: true,
                rawNumber: value
            )

        case .number:
            guard let spec = section.number else { break }
            // A negative section supplies its own sign; only a single-section format adds one.
            let usesOwnSign = format.sections.prefix(3).count > 1 || section.condition != nil
            let magnitude = usesOwnSign ? abs(value) : value
            return CellDisplay(
                text: numberText(magnitude, spec: spec, fractionHasWholePart: Self.hasWholePart(section)),
                horizontal: horizontal,
                vertical: style.alignment.vertical,
                color: color,
                isNumeric: true,
                fillCharacter: spec.fillCharacter?.first,
                isAccounting: spec.isAccounting,
                rawNumber: value
            )

        case .general:
            break
        }

        return CellDisplay(
            text: Self.generalText(value, budget: Self.defaultGeneralBudget),
            horizontal: horizontal,
            vertical: style.alignment.vertical,
            color: color,
            isNumeric: true,
            isGeneralNumber: true,
            rawNumber: value
        )
    }

    /// Whether a fraction format carries a whole-number part.
    ///
    /// `# ?/?` shows `2 1/2`; `?/?` shows `5/2`. Excel tells them apart by the space before the
    /// numerator, and ``NumberFormat/NumberSpec/minimumIntegerDigits`` cannot: it counts `0`
    /// placeholders, and the integer part of a fraction format is conventionally written `#`.
    static func hasWholePart(_ section: NumberFormat.Section) -> Bool {
        section.raw.prefix { $0 != "/" }.contains(" ")
    }

    /// Renders a magnitude through one section's ``NumberFormat/NumberSpec``.
    func numberText(_ value: Double, spec: NumberFormat.NumberSpec, fractionHasWholePart: Bool = false) -> String {
        guard value.isFinite else { return CellError.invalidNumber.rawValue }
        let scaled = value * spec.scale
        let negative = scaled < 0
        let magnitude = abs(scaled)

        let body: String = if spec.isScientific {
            Self.scientificBody(magnitude, spec: spec)
        } else if let fraction = spec.fraction {
            Self.fractionBody(magnitude, spec: spec, fraction: fraction, hasWholePart: fractionHasWholePart)
        } else {
            Self.fixedBody(magnitude, spec: spec)
        }

        // In `# ?/?` the space that separates the whole part from the numerator is scanned as a
        // literal and lands in the suffix, but the fraction body already reproduces it. Dropping a
        // whitespace-only affix avoids the double space without touching `# ?/? "kg"`.
        let prefix = spec.fraction != nil && spec.prefix.allSatisfy(\.isWhitespace) ? "" : spec.prefix
        let suffix = spec.fraction != nil && spec.suffix.allSatisfy(\.isWhitespace) ? "" : spec.suffix
        return (negative ? "-" : "") + prefix + body + suffix
    }

    // MARK: - Fixed point

    private static func fixedBody(_ magnitude: Double, spec: NumberFormat.NumberSpec) -> String {
        let digits = max(0, min(spec.maximumFractionDigits, 20))
        var (integer, fraction) = splitFixed(magnitude, decimals: digits)

        // `?` positions pad with spaces so decimal points line up down a column; `0` positions
        // pad with zeros. Trailing `#` positions are dropped entirely.
        let keep = max(spec.minimumFractionDigits, spec.alignedFractionDigits)
        while fraction.count > keep, fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        while fraction.count < spec.minimumFractionDigits {
            fraction.append("0")
        }
        if fraction.count < spec.alignedFractionDigits {
            fraction += String(repeating: " ", count: spec.alignedFractionDigits - fraction.count)
        }

        while integer.count < spec.minimumIntegerDigits {
            integer = "0" + integer
        }
        if integer == "0", spec.minimumIntegerDigits == 0 {
            integer = ""
        }
        if spec.usesThousandsSeparator {
            integer = group(integer)
        }
        return fraction.isEmpty ? integer : integer + "." + fraction
    }

    /// Splits a non-negative magnitude into integer and fraction digit strings, rounding **half
    /// away from zero** — Excel's rule, not `printf`'s round-half-to-even.
    ///
    /// `0.5` under `0` is `1` in Excel and `0` under `%.0f`. That is a visible, complained-about
    /// difference in a column of prices.
    static func splitFixed(_ magnitude: Double, decimals: Int) -> (integer: String, fraction: String) {
        guard magnitude.isFinite else { return ("0", "") }
        // Beyond 2^53 every double is already an integer, and scaling would lose more than it
        // gains, so hand those to `printf` untouched.
        if magnitude >= 1e15 {
            let text = String(format: "%.\(decimals)f", magnitude)
            let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        }
        let factor = pow(10.0, Double(decimals))
        let scaled = (magnitude * factor).rounded(.toNearestOrAwayFromZero)
        // `String(format:)` goes through `CFStringAppendFormatCore`, which showed up in a profile
        // of the draw loop. Every value that reaches here fits in an `Int64`, and `String(Int64)`
        // is several times cheaper and allocates less.
        var digits = scaled < 9.2e18 ? String(Int64(scaled)) : String(format: "%.0f", scaled)
        if digits.count <= decimals {
            digits = String(repeating: "0", count: decimals - digits.count + 1) + digits
        }
        let splitIndex = digits.index(digits.endIndex, offsetBy: -decimals)
        return (String(digits[digits.startIndex ..< splitIndex]), String(digits[splitIndex...]))
    }

    /// Inserts thousands separators into a run of digits.
    static func group(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) { result.append(",") }
            result.append(character)
        }
        return result
    }

    // MARK: - Scientific

    private static func scientificBody(_ magnitude: Double, spec: NumberFormat.NumberSpec) -> String {
        guard magnitude > 0 else {
            let zero = fixedBody(0, spec: spec)
            return zero + "E" + (spec.exponentAlwaysSigned ? "+" : "") + String(
                repeating: "0", count: max(1, spec.exponentDigits)
            )
        }
        var exponent = Int(floor(log10(magnitude)))
        // The integer placeholders decide the mantissa's magnitude: `##0.0E+0` steps in threes.
        let integerDigits = max(1, spec.minimumIntegerDigits)
        exponent -= (exponent % integerDigits + integerDigits) % integerDigits == 0
            ? 0
            : (exponent % integerDigits + integerDigits) % integerDigits
        exponent -= integerDigits - 1
        var mantissa = magnitude / pow(10, Double(exponent))
        // Rounding the mantissa can push it to the next decade — 9.99 at one decimal is 10.0.
        let decimals = max(0, spec.maximumFractionDigits)
        if (mantissa * pow(10, Double(decimals))).rounded(.toNearestOrAwayFromZero)
            >= pow(10, Double(decimals + integerDigits)) {
            mantissa /= pow(10, Double(integerDigits))
            exponent += integerDigits
        }
        let (integer, fraction) = splitFixed(mantissa, decimals: decimals)
        var body = integer
        var padded = fraction
        while padded.count < spec.minimumFractionDigits { padded.append("0") }
        while padded.count > spec.minimumFractionDigits, padded.hasSuffix("0") { padded.removeLast() }
        if !padded.isEmpty { body += "." + padded }

        let sign = exponent < 0 ? "-" : (spec.exponentAlwaysSigned ? "+" : "")
        var exponentDigits = String(abs(exponent))
        while exponentDigits.count < max(1, spec.exponentDigits) { exponentDigits = "0" + exponentDigits }
        return body + "E" + sign + exponentDigits
    }

    // MARK: - Fractions

    private static func fractionBody(
        _ magnitude: Double,
        spec: NumberFormat.NumberSpec,
        fraction: NumberFormat.FractionSpec,
        hasWholePart: Bool
    ) -> String {
        let whole = hasWholePart ? magnitude.rounded(.towardZero) : 0
        let remainder = magnitude - whole
        let limit: Int = if let fixed = fraction.fixedDenominator, fixed > 0 {
            fixed
        } else {
            Int(pow(10, Double(max(1, fraction.denominatorDigits)))) - 1
        }

        let (numerator, denominator): (Int, Int)
        if let fixed = fraction.fixedDenominator, fixed > 0 {
            let scaled = (remainder * Double(fixed)).rounded(.toNearestOrAwayFromZero)
            numerator = scaled.isFinite ? Int(scaled) : 0
            denominator = fixed
        } else if hasWholePart || remainder < 1 {
            (numerator, denominator) = bestRational(remainder, maximumDenominator: max(1, limit))
        } else {
            // A pure fraction format renders an improper fraction: `?/?` shows 2.5 as `5/2`.
            let base = bestRational(
                remainder.truncatingRemainder(dividingBy: 1), maximumDenominator: max(1, limit)
            )
            let wholePart = Int(remainder.rounded(.towardZero))
            numerator = base.numerator + wholePart * base.denominator
            denominator = base.denominator
        }

        var parts: [String] = []
        if hasWholePart {
            let integer = whole < 9.2e18 ? String(Int64(whole)) : String(format: "%.0f", whole)
            parts.append(spec.usesThousandsSeparator ? group(integer) : integer)
        }
        if numerator != 0 {
            parts.append("\(numerator)/\(denominator)")
        } else if parts.isEmpty {
            parts.append("0")
        }
        return parts.joined(separator: " ")
    }

    /// The closest fraction with a denominator no larger than `maximumDenominator`, by Stern–Brocot
    /// descent. Excel picks the same one for every case that matters.
    static func bestRational(_ value: Double, maximumDenominator: Int) -> (numerator: Int, denominator: Int) {
        guard value > 0, value < 1, maximumDenominator > 1 else { return (0, max(1, maximumDenominator)) }
        var lowNumerator = 0, lowDenominator = 1
        var highNumerator = 1, highDenominator = 1
        for _ in 0 ..< 64 {
            let mediantNumerator = lowNumerator + highNumerator
            let mediantDenominator = lowDenominator + highDenominator
            guard mediantDenominator <= maximumDenominator else { break }
            if Double(mediantNumerator) < value * Double(mediantDenominator) {
                lowNumerator = mediantNumerator
                lowDenominator = mediantDenominator
            } else {
                highNumerator = mediantNumerator
                highDenominator = mediantDenominator
            }
        }
        let lowError = abs(value - Double(lowNumerator) / Double(lowDenominator))
        let highError = abs(value - Double(highNumerator) / Double(highDenominator))
        return lowError <= highError ? (lowNumerator, lowDenominator) : (highNumerator, highDenominator)
    }

    // MARK: - Dates

    /// Renders a serial number through a date pattern.
    func dateText(_ serial: Double, spec: NumberFormat.DateSpec) -> String {
        if spec.hasElapsedComponents {
            return Self.elapsedText(serial, spec: spec)
        }
        // Excel shows `#####` for a negative serial rather than a date before its epoch.
        guard serial >= 0 else { return "" }
        let parts = SerialDate.components(serial: serial, system: dateSystem)
        var result = ""
        let twelveHour = spec.usesTwelveHourClock
        for token in spec.tokens {
            result += Self.render(token, parts: parts, twelveHour: twelveHour)
        }
        return result
    }

    private static func render(_ token: NumberFormat.DateToken, parts: DateTimeComponents, twelveHour: Bool) -> String {
        switch token {
        case let .year(digits):
            let year = parts.year
            return digits <= 2 ? pad(abs(year) % 100, 2) : pad(year, max(4, digits))
        case let .month(digits):
            switch digits {
            case 1, 2: return pad(parts.month, digits)
            case 3: return monthNames.short[safe: parts.month - 1] ?? ""
            case 4: return monthNames.long[safe: parts.month - 1] ?? ""
            default: return String((monthNames.long[safe: parts.month - 1] ?? " ").prefix(1))
            }
        case let .day(digits):
            switch digits {
            case 1, 2: return pad(parts.day, digits)
            case 3: return weekdayNames.short[safe: parts.weekday - 1] ?? ""
            default: return weekdayNames.long[safe: parts.weekday - 1] ?? ""
            }
        case let .hour(digits):
            let hour = twelveHour ? (parts.hour % 12 == 0 ? 12 : parts.hour % 12) : parts.hour
            return pad(hour, digits)
        case let .minute(digits):
            return pad(parts.minute, digits)
        case let .second(digits):
            return pad(parts.second, digits)
        case let .fractionalSeconds(digits):
            let scaled = Int((Double(parts.millisecond) / 1000 * pow(10, Double(digits))).rounded())
            return "." + pad(scaled, digits)
        case let .amPm(style):
            let isMorning = parts.hour < 12
            switch style {
            case .upperLong: return isMorning ? "AM" : "PM"
            case .lowerLong: return isMorning ? "am" : "pm"
            case .upperShort: return isMorning ? "A" : "P"
            case .lowerShort: return isMorning ? "a" : "p"
            }
        case .era:
            // Japanese eras round-trip but are not rendered — guessing is worse than omitting.
            return ""
        case let .elapsedHours(digits):
            return pad(Int((Double(parts.hour))), digits)
        case let .elapsedMinutes(digits):
            return pad(parts.minute, digits)
        case let .elapsedSeconds(digits):
            return pad(parts.second, digits)
        case let .literal(text):
            return text
        }
    }

    /// `[h]:mm:ss` describes a duration, so the serial is a count of days and never a date.
    private static func elapsedText(_ serial: Double, spec: NumberFormat.DateSpec) -> String {
        let negative = serial < 0
        let totalSeconds = (abs(serial) * 86400).rounded()
        var result = negative ? "-" : ""
        for token in spec.tokens {
            switch token {
            case let .elapsedHours(digits):
                result += pad(Int(totalSeconds / 3600), digits)
            case let .elapsedMinutes(digits):
                result += pad(Int(totalSeconds / 60), digits)
            case let .elapsedSeconds(digits):
                result += pad(Int(totalSeconds), digits)
            case let .minute(digits):
                result += pad(Int(totalSeconds.truncatingRemainder(dividingBy: 3600) / 60), digits)
            case let .second(digits):
                result += pad(Int(totalSeconds.truncatingRemainder(dividingBy: 60)), digits)
            case let .hour(digits):
                result += pad(Int(totalSeconds / 3600) % 24, digits)
            case let .literal(text):
                result += text
            default:
                break
            }
        }
        return result
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        let padded = text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
        return value < 0 ? "-" + padded : padded
    }

    private static let monthNames = (
        short: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
        long: [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]
    )

    private static let weekdayNames = (
        short: ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
        long: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    )

    // MARK: - Text sections

    /// Substitutes the cell's text for the `@` placeholder, keeping the section's literals.
    private func applyTextSection(_ section: NumberFormat.Section, to text: String) -> String {
        guard section.raw.contains("@") else { return section.literalText.isEmpty ? text : section.literalText }
        var result = ""
        var quoted = false
        var escaped = false
        for character in section.raw {
            if escaped {
                result.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "\"":
                quoted.toggle()
            case "@" where !quoted:
                result += text
            case "[" where !quoted, "]" where !quoted:
                continue
            default:
                result.append(character)
            }
        }
        return result
    }

    // MARK: - General

    /// How many characters `General` aims to fit into a default-width column. Excel's own limit.
    static let defaultGeneralBudget = 11

    /// Excel's `General`: as many significant digits as fit, then scientific notation.
    ///
    /// The budget is a *character* count, not a digit count, because that is what Excel actually
    /// measures — which is why the same number shows more decimals in a wider column.
    public static func generalText(_ value: Double, budget: Int) -> String {
        guard value.isFinite else { return CellError.invalidNumber.rawValue }
        guard value != 0 else { return "0" }

        let budget = max(1, budget)
        let magnitude = abs(value)
        let signCost = value < 0 ? 1 : 0

        // Outside this window Excel always goes scientific, whatever the column width.
        if magnitude >= 1e11 || magnitude < 1e-10 {
            return scientificGeneral(value, budget: budget)
        }

        let integerDigits = magnitude < 1 ? 1 : Int(floor(log10(magnitude))) + 1
        if integerDigits + signCost > budget {
            return scientificGeneral(value, budget: budget)
        }

        // One character goes to the decimal point, and Excel never shows more than 15
        // significant digits because a `Double` does not have more than that to show.
        var decimals = budget - integerDigits - signCost - 1
        decimals = max(0, min(decimals, 15 - integerDigits))

        let (integer, fraction) = splitFixed(magnitude, decimals: decimals)
        var trimmed = fraction
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        let sign = value < 0 ? "-" : ""
        let rendered = trimmed.isEmpty ? sign + integer : sign + integer + "." + trimmed
        return rendered.count <= budget ? rendered : scientificGeneral(value, budget: budget)
    }

    private static func scientificGeneral(_ value: Double, budget: Int) -> String {
        let magnitude = abs(value)
        let exponent = magnitude > 0 ? Int(floor(log10(magnitude))) : 0
        let exponentText = "E" + (exponent < 0 ? "-" : "+") + (abs(exponent) < 10 ? "0" : "")
            + String(abs(exponent))
        let sign = value < 0 ? "-" : ""
        let overhead = exponentText.count + sign.count + 2
        let decimals = max(0, min(5, budget - overhead))
        let mantissa = magnitude / pow(10, Double(exponent))
        let (integer, fraction) = splitFixed(mantissa, decimals: decimals)
        var trimmed = fraction
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        let body = trimmed.isEmpty ? integer : integer + "." + trimmed
        return sign + body + exponentText
    }

    /// The shortest decimal string that reads back as the same `Double` — what the editor and
    /// the formula bar show, so a round-trip through the editor cannot lose precision.
    static func roundTripText(_ value: Double) -> String {
        guard value.isFinite else { return CellError.invalidNumber.rawValue }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return "\(value)"
    }

    // MARK: - Helpers

    private func resolve(
        _ horizontal: CellAlignment.Horizontal,
        default fallback: CellAlignment.Horizontal
    ) -> CellAlignment.Horizontal {
        switch horizontal {
        case .general: fallback
        // `centerContinuous` centres across a run of cells; without the run it is plain centring.
        case .centerContinuous: .center
        // `justify` and `distributed` only differ from the base alignment when text wraps.
        case .justify, .distributed: fallback == .right ? .right : .left
        default: horizontal
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
