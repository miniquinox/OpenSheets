import Foundation
import SheetModel

/// What a typed string turned into.
public struct ParsedCellInput: Sendable, Hashable {
    /// The formula source **without** its leading `=`, matching ``SheetModel/Cell/formula``.
    public var formula: String?
    /// The value to store. For a formula this is the placeholder until the engine runs.
    public var value: CellValue
    /// A built-in number-format id the input implies — `9` for `50%`, `14` for `3/4/2026`.
    ///
    /// Only ever *suggested*: a cell that already carries an explicit format keeps it, because
    /// typing `1000` into a column formatted as currency must not turn that cell back to General.
    public var suggestedNumberFormatID: Int32?

    public init(formula: String? = nil, value: CellValue, suggestedNumberFormatID: Int32? = nil) {
        self.formula = formula
        self.value = value
        self.suggestedNumberFormatID = suggestedNumberFormatID
    }
}

/// PLAN.md §8's input parsing order, in one place.
///
/// > formula (`=`) → boolean → number (locale-aware, with thousands separators,
/// > parentheses-negative, trailing %) → currency → date/time (locale + ISO) → text.
/// > Explicit override via number format. Leading `'` forces text.
///
/// Two rules here are not obvious and both come from the corpus rather than from taste:
///
/// - **`#N/A` typed into a cell is an error value, not the text `#N/A`.** Wave 1 addendum §4.
///   Excel does this, our CSV import does this, and the MCP write path does this; a grid that
///   disagreed with all three would be the odd one out.
/// - **A cell whose existing format is Text (`@`) takes the input verbatim.** That is what the
///   format means, and it is the only way a user can keep a leading zero or a long digit string
///   without prefixing every entry with an apostrophe.
public enum CellInputParser {
    /// Parses `text` for a cell that currently carries `format`.
    public static func parse(
        _ text: String,
        format: NumberFormat = .general,
        dateSystem: DateSystem = .excel1900,
        locale: Locale = .autoupdatingCurrent
    ) -> ParsedCellInput {
        // Leading apostrophe forces text, and the apostrophe itself is not part of the value.
        if text.hasPrefix("'") {
            return ParsedCellInput(value: .text(String(text.dropFirst())))
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return ParsedCellInput(value: .empty) }

        // A formula is a formula whatever the cell's format says — you cannot format your way out
        // of `=`. (A Text-formatted cell in Excel does store `=A1` as text; we deliberately do
        // not, because the cell is then a lie that only reveals itself on the next recalculation.)
        if trimmed.hasPrefix("="), trimmed.count > 1 {
            return ParsedCellInput(formula: String(trimmed.dropFirst()), value: .empty)
        }

        if format.kind == .text { return ParsedCellInput(value: .text(text)) }

        if let boolean = boolean(trimmed) { return ParsedCellInput(value: .boolean(boolean)) }

        if let error = CellError(rawValue: trimmed.uppercased()), error.isExcelNative {
            return ParsedCellInput(value: .error(error))
        }

        if let number = number(trimmed, locale: locale) {
            return ParsedCellInput(
                value: .number(number.value),
                suggestedNumberFormatID: format.isGeneral ? number.formatID : nil
            )
        }

        if let date = date(trimmed, dateSystem: dateSystem, locale: locale) {
            return ParsedCellInput(
                value: .number(date.serial),
                suggestedNumberFormatID: format.isGeneral ? date.formatID : nil
            )
        }

        return ParsedCellInput(value: .text(text))
    }

    // MARK: - Booleans

    private static func boolean(_ text: String) -> Bool? {
        switch text.uppercased() {
        case "TRUE": true
        case "FALSE": false
        default: nil
        }
    }

    // MARK: - Numbers

    struct NumberResult {
        var value: Double
        /// `nil` for a plain number: General renders it fine and pinning a format would stop the
        /// column's own format from applying later.
        var formatID: Int32?
    }

    static func number(_ text: String, locale: Locale) -> NumberResult? {
        var body = text
        var sign = 1.0
        var formatID: Int32?

        // Accounting negatives: (1,234.50) is -1234.5.
        if body.hasPrefix("("), body.hasSuffix(")"), body.count > 2 {
            sign = -1
            body = String(body.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }

        var isPercent = false
        if body.hasSuffix("%") {
            isPercent = true
            body = String(body.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // The sign comes off before the currency symbol, because `-$5` puts it outside and
        // `$-5` puts it inside and both are things people type.
        if body.hasPrefix("-") || body.hasPrefix("+") {
            if body.hasPrefix("-") { sign *= -1 }
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Currency, leading or trailing. `symbol` may be several characters ("CHF", "kr").
        let symbols = currencySymbols(locale)
        for symbol in symbols where !symbol.isEmpty {
            if body.hasPrefix(symbol) {
                body = String(body.dropFirst(symbol.count)).trimmingCharacters(in: .whitespaces)
                formatID = 44
                break
            }
            if body.hasSuffix(symbol) {
                body = String(body.dropLast(symbol.count)).trimmingCharacters(in: .whitespaces)
                formatID = 44
                break
            }
        }
        if formatID == 44, body.hasPrefix("-") {
            sign *= -1
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        guard let magnitude = plainNumber(body, locale: locale) else { return nil }

        if isPercent {
            // `9` is `0%`, `10` is `0.00%`. Match what the user typed rather than always picking
            // one: entering `12.5%` and getting `13%` back reads as a rounding bug.
            formatID = body.contains(decimalSeparator(locale)) ? 10 : 9
            return NumberResult(value: sign * magnitude / 100, formatID: formatID)
        }
        return NumberResult(value: sign * magnitude, formatID: formatID)
    }

    /// A number with optional grouping separators and an optional exponent. Deliberately strict:
    /// anything with a stray character is text, not a number with rubbish in it.
    private static func plainNumber(_ text: String, locale: Locale) -> Double? {
        guard !text.isEmpty else { return nil }
        let decimal = decimalSeparator(locale)
        let grouping = groupingSeparator(locale)

        var normalised = text
        if !grouping.isEmpty { normalised = normalised.replacingOccurrences(of: grouping, with: "") }
        // Some locales group with a non-breaking or narrow no-break space.
        normalised = normalised.replacingOccurrences(of: "\u{00A0}", with: "")
        normalised = normalised.replacingOccurrences(of: "\u{202F}", with: "")
        if decimal != "." { normalised = normalised.replacingOccurrences(of: decimal, with: ".") }

        // Reject anything that is not a plain decimal literal. `Double("1_0")`, `Double("nan")`
        // and `Double("0x1p3")` all succeed, and none of them is what somebody typed into a cell.
        var seenDigit = false
        var seenDot = false
        var seenExponent = false
        for (index, character) in normalised.enumerated() {
            switch character {
            case "0" ... "9":
                seenDigit = true
            case ".":
                if seenDot || seenExponent { return nil }
                seenDot = true
            case "e", "E":
                if seenExponent || !seenDigit { return nil }
                seenExponent = true
                seenDigit = false
            case "+", "-":
                let previous = index == 0 ? nil : Array(normalised)[index - 1]
                if index != 0, previous != "e", previous != "E" { return nil }
            default:
                return nil
            }
        }
        guard seenDigit else { return nil }
        return Double(normalised)
    }

    private static func decimalSeparator(_ locale: Locale) -> String {
        locale.decimalSeparator ?? "."
    }

    private static func groupingSeparator(_ locale: Locale) -> String {
        locale.groupingSeparator ?? ","
    }

    private static func currencySymbols(_ locale: Locale) -> [String] {
        var symbols: [String] = []
        if let symbol = locale.currencySymbol, !symbol.isEmpty { symbols.append(symbol) }
        symbols.append(contentsOf: ["$", "€", "£", "¥", "₹", "₽", "₩"])
        // Longest first, so "CHF" is not half-eaten by "C".
        return Array(Set(symbols)).sorted { $0.count > $1.count }
    }

    // MARK: - Dates

    struct DateResult {
        var serial: Double
        var formatID: Int32
    }

    static func date(_ text: String, dateSystem: DateSystem, locale: Locale) -> DateResult? {
        if let components = isoDateTime(text) {
            guard let serial = SerialDate.serial(from: components, system: dateSystem) else { return nil }
            let hasTime = components.hour != 0 || components.minute != 0 || components.second != 0
            return DateResult(serial: serial, formatID: hasTime ? 22 : 14)
        }
        if let components = timeOnly(text) {
            guard let serial = SerialDate.serial(from: components, system: dateSystem) else { return nil }
            // A bare time is a fraction of a day, so drop the date part entirely.
            return DateResult(serial: serial - serial.rounded(.down), formatID: 21)
        }
        return localeDate(text, dateSystem: dateSystem, locale: locale)
    }

    /// `2026-08-23`, optionally `T14:22[:05]` or ` 14:22[:05]`.
    private static func isoDateTime(_ text: String) -> DateTimeComponents? {
        let parts = text.split(whereSeparator: { $0 == "T" || $0 == " " })
        guard let datePart = parts.first else { return nil }
        let numbers = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers[0].count == 4,
              let year = Int(numbers[0]), let month = Int(numbers[1]), let day = Int(numbers[2]),
              month >= 1, month <= 12, day >= 1, day <= SerialDate.daysInMonth(year: year, month: month)
        else { return nil }

        var hour = 0
        var minute = 0
        var second = 0
        if parts.count == 2 {
            guard let time = clockComponents(String(parts[1])) else { return nil }
            (hour, minute, second) = time
        } else if parts.count > 2 {
            return nil
        }
        return DateTimeComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
    }

    private static func timeOnly(_ text: String) -> DateTimeComponents? {
        guard text.contains(":"), let time = clockComponents(text) else { return nil }
        // Anchored on the epoch day so the fractional part is the time and nothing else.
        return DateTimeComponents(
            year: 1900, month: 1, day: 1, hour: time.0, minute: time.1, second: time.2
        )
    }

    private static func clockComponents(_ text: String) -> (Int, Int, Int)? {
        var body = text.uppercased().trimmingCharacters(in: .whitespaces)
        var meridiemOffset = 0
        var isMeridiem = false
        for suffix in ["AM", "PM", " AM", " PM"] where body.hasSuffix(suffix) {
            isMeridiem = true
            if suffix.hasSuffix("PM") { meridiemOffset = 12 }
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let fields = body.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 2, fields.count <= 3 else { return nil }
        guard var hour = Int(fields[0]), let minute = Int(fields[1]) else { return nil }
        let second = fields.count == 3 ? Int(fields[2]) : 0
        guard let second else { return nil }
        guard minute >= 0, minute < 60, second >= 0, second < 60 else { return nil }
        if isMeridiem {
            guard hour >= 1, hour <= 12 else { return nil }
            hour = hour % 12 + meridiemOffset
        }
        guard hour >= 0, hour < 24 else { return nil }
        return (hour, minute, second)
    }

    /// The user's own short and medium date styles, and nothing else.
    ///
    /// `DateFormatter` in `.lenient` mode will happily read "42" as a date. It is off, and the
    /// candidate list is short on purpose: a spreadsheet where some strings silently became dates
    /// is a spreadsheet nobody trusts again.
    private static func localeDate(
        _ text: String,
        dateSystem: DateSystem,
        locale: Locale
    ) -> DateResult? {
        guard text.contains("/") || text.contains("-") || text.contains(".") else { return nil }
        for style in [DateFormatter.Style.short, .medium] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = .gmt
            formatter.dateStyle = style
            formatter.timeStyle = .none
            formatter.isLenient = false
            guard let date = formatter.date(from: text) else { continue }
            return DateResult(
                serial: SerialDate.serial(from: date, system: dateSystem, timeZone: .gmt).rounded(),
                formatID: 14
            )
        }
        return nil
    }
}
