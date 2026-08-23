import Foundation
import SheetModel

/// Renders a value through a number-format code, for `TEXT()`.
///
/// Deliberately **not** a general grid renderer — that is A4's job and it has to deal with
/// column widths, fill characters, and colour. This covers what `TEXT()` needs: pick the right
/// section, then turn a number into digits or a date into fields, using the already-parsed
/// ``NumberFormat`` rather than re-scanning the code.
///
/// Month and weekday names are English. Excel localises them from the workbook's locale, which
/// OpenSheets does not model; a `TEXT(…,"mmmm")` in a French workbook will therefore say
/// `March` where Excel says `mars`. That is a known divergence, and it is a smaller lie than
/// guessing at a locale we were never told.
enum ExcelTextFormat {
    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func render(_ value: ScalarValue, format: NumberFormat, dateSystem: DateSystem) throws -> String {
        if case let .error(error) = value { throw FormulaFault.cell(error) }
        if case let .text(text) = value {
            guard let section = format.textSection else { return text }
            return section.raw.contains("@") ? renderTextSection(section, text: text) : section.literalText
        }
        let number: Double
        switch value {
        case let .number(raw): number = raw
        case let .boolean(flag): number = flag ? 1 : 0
        case .blank: number = 0
        default: number = 0
        }
        guard let section = format.section(forNumber: number) else { return ExcelNumber.generalText(number) }
        switch section.kind {
        case .general:
            return ExcelNumber.generalText(number)
        case .blank:
            return ""
        case .text:
            return section.literalText
        case .date:
            guard let spec = section.date else { return ExcelNumber.generalText(number) }
            return renderDate(number, spec: spec, dateSystem: dateSystem)
        case .number:
            guard let spec = section.number else { return ExcelNumber.generalText(number) }
            let suppliesSign = format.sections.count >= 2 && number < 0
                && !format.sections.contains { $0.condition != nil }
            return renderNumber(number, spec: spec, signIsInFormat: suppliesSign)
        }
    }

    private static func renderTextSection(_ section: NumberFormat.Section, text: String) -> String {
        var result = ""
        for character in section.raw {
            if character == "@" { result += text } else if character != "\"" { result.append(character) }
        }
        return result
    }

    // MARK: - Numbers

    static func renderNumber(_ value: Double, spec: NumberFormat.NumberSpec, signIsInFormat: Bool) -> String {
        let scaled = value * spec.scale
        let negative = scaled < 0
        let magnitude = abs(scaled)

        var digits: String
        if spec.isScientific {
            digits = scientific(magnitude, spec: spec)
        } else {
            digits = fixed(magnitude, spec: spec)
        }
        if negative, !signIsInFormat { digits = "-" + digits }
        return spec.prefix + digits + spec.suffix
    }

    private static func fixed(_ magnitude: Double, spec: NumberFormat.NumberSpec) -> String {
        let places = min(max(spec.maximumFractionDigits, 0), 15)
        // Round explicitly rather than leaving it to `%f`, which rounds half to *even*:
        // `TEXT(1234.5,"0")` is `1235` in Excel and would be `1234` through printf alone.
        let scale = pow(10.0, Double(places))
        let snapped = scale.isFinite && scale > 0
            ? (magnitude * scale).rounded(.toNearestOrAwayFromZero) / scale
            : magnitude
        let text = String(format: "%.\(places)f", snapped.isFinite ? snapped : magnitude)
        var integerPart = text
        var fractionPart = ""
        if let dot = text.firstIndex(of: ".") {
            integerPart = String(text[text.startIndex ..< dot])
            fractionPart = String(text[text.index(after: dot)...])
        }
        // `#.##` keeps only as many decimals as it needs; `0.00` keeps exactly two.
        while fractionPart.count > spec.minimumFractionDigits, fractionPart.hasSuffix("0") {
            fractionPart.removeLast()
        }
        while integerPart.count < spec.minimumIntegerDigits {
            integerPart = "0" + integerPart
        }
        if spec.minimumIntegerDigits == 0, integerPart == "0" { integerPart = "" }
        if spec.usesThousandsSeparator { integerPart = grouped(integerPart) }
        return fractionPart.isEmpty ? integerPart : integerPart + "." + fractionPart
    }

    private static func scientific(_ magnitude: Double, spec: NumberFormat.NumberSpec) -> String {
        let places = min(max(spec.maximumFractionDigits, 0), 15)
        var text = String(format: "%.\(places)E", magnitude)
        guard let marker = text.firstIndex(of: "E") else { return text }
        let mantissa = String(text[text.startIndex ..< marker])
        var exponentText = String(text[text.index(after: marker)...])
        var sign = "+"
        if exponentText.hasPrefix("-") {
            sign = "-"
            exponentText.removeFirst()
        } else if exponentText.hasPrefix("+") {
            exponentText.removeFirst()
        }
        while exponentText.count > max(spec.exponentDigits, 1), exponentText.hasPrefix("0") {
            exponentText.removeFirst()
        }
        while exponentText.count < spec.exponentDigits { exponentText = "0" + exponentText }
        text = mantissa + "E" + (sign == "-" || spec.exponentAlwaysSigned ? sign : "") + exponentText
        return text
    }

    private static func grouped(_ digits: String) -> String {
        guard digits.count > 3 else { return digits }
        var result = ""
        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return String(result.reversed())
    }

    // MARK: - Dates

    static func renderDate(_ serial: Double, spec: NumberFormat.DateSpec, dateSystem: DateSystem) -> String {
        let parts = SerialDate.components(serial: serial, system: dateSystem)
        let totalHours = serial * 24
        var result = ""
        for token in spec.tokens {
            result += renderToken(token, parts: parts, spec: spec, serial: serial, totalHours: totalHours)
        }
        return result
    }

    private static func renderToken(
        _ token: NumberFormat.DateToken,
        parts: DateTimeComponents,
        spec: NumberFormat.DateSpec,
        serial: Double,
        totalHours: Double
    ) -> String {
        switch token {
        case let .year(digits):
            return digits <= 2 ? pad(parts.year % 100, 2) : pad(parts.year, 4)
        case let .month(digits):
            let index = max(min(parts.month, 12), 1) - 1
            switch digits {
            case 1: return String(parts.month)
            case 2: return pad(parts.month, 2)
            case 3: return String(monthNames[index].prefix(3))
            case 4: return monthNames[index]
            default: return String(monthNames[index].prefix(1))
            }
        case let .day(digits):
            let weekday = max(min(parts.weekday, 7), 1) - 1
            switch digits {
            case 1: return String(parts.day)
            case 2: return pad(parts.day, 2)
            case 3: return String(weekdayNames[weekday].prefix(3))
            default: return weekdayNames[weekday]
            }
        case let .hour(digits):
            var hour = parts.hour
            if spec.usesTwelveHourClock {
                hour %= 12
                if hour == 0 { hour = 12 }
            }
            return digits <= 1 ? String(hour) : pad(hour, 2)
        case let .minute(digits):
            return digits <= 1 ? String(parts.minute) : pad(parts.minute, 2)
        case let .second(digits):
            return digits <= 1 ? String(parts.second) : pad(parts.second, 2)
        case let .elapsedHours(digits):
            return pad(Int(totalHours.rounded(.towardZero)), digits)
        case let .elapsedMinutes(digits):
            return pad(Int((serial * 1440).rounded(.towardZero)), digits)
        case let .elapsedSeconds(digits):
            return pad(Int((serial * 86_400).rounded(.towardZero)), digits)
        case let .fractionalSeconds(digits):
            let fraction = Double(parts.millisecond) / 1000
            return "." + String(format: "%0\(max(digits, 1))d", Int((fraction * pow(10, Double(digits))).rounded()))
        case let .amPm(style):
            let isMorning = parts.hour < 12
            switch style {
            case .upperLong: return isMorning ? "AM" : "PM"
            case .lowerLong: return isMorning ? "am" : "pm"
            case .upperShort: return isMorning ? "A" : "P"
            case .lowerShort: return isMorning ? "a" : "p"
            }
        case .era:
            return ""
        case let .literal(text):
            return text
        }
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(abs(value))
        let padding = width > text.count ? String(repeating: "0", count: width - text.count) : ""
        return (value < 0 ? "-" : "") + padding + text
    }
}
