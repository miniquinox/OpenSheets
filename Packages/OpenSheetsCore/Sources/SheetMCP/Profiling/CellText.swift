import Foundation
import SheetModel

/// Renders cell values for an agent to read.
///
/// Deliberately **not** GridKit's formatter. The grid formats for a human looking at a
/// spreadsheet: locale-aware, format-code-faithful, column-width-aware. An agent wants the
/// opposite — the value, unambiguously, in a form it can compare and compute with. `1234.5`
/// beats `$1,234.50` when the next thing that happens is arithmetic, and `2026-03-01` beats
/// `1-Mar-26` for the same reason.
///
/// The one place the format code *is* consulted is date detection, because there a serial
/// number and a date are the same bits and only the format says which one the file means.
public enum CellText {
    /// A cell as plain text: numbers unformatted, dates as ISO-8601, errors as their token.
    ///
    /// Never wrapped and never escaped — the caller decides whether it is going inside an
    /// untrusted envelope, a TSV row, or a JSON string, and each of those escapes differently.
    public static func plain(_ cell: Cell, styles: StyleTable, dateSystem: DateSystem = .excel1900) -> String {
        switch cell.value {
        case .empty:
            return ""
        case let .text(value):
            return value
        case let .boolean(value):
            return value ? "TRUE" : "FALSE"
        case let .error(value):
            return value.xlsxToken
        case let .number(value):
            let format = styles.numberFormat(for: cell.styleID)
            switch format.kind {
            case .date, .dateTime, .time:
                return temporal(value, kind: format.kind, system: dateSystem) ?? number(value)
            default:
                return number(value)
            }
        }
    }

    /// A number with no thousands separators, no currency, and no trailing `.0`.
    ///
    /// `%.15g` rather than `String(describing:)`: Swift prints the shortest round-tripping
    /// representation, which for a value that came out of a spreadsheet is often
    /// `0.30000000000000004`. Fifteen significant digits is what Excel itself stores and shows,
    /// so this is the spelling that matches the file.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "#NUM!" }
        if value.rounded() == value, value.magnitude < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.15g", value)
        if text.contains("e") || text.contains("E") { return text }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// A number for a *summary* line, not for a cell.
    ///
    /// Fifteen significant digits is right for a value that has to round-trip; it is wrong for
    /// a column total, where it turns a sum of prices into `1999660.24000001` and tells an
    /// agent the data has more precision than it does. Twelve digits is past anything a
    /// spreadsheet stores meaningfully and absorbs the accumulated binary error of a long sum.
    public static func approximate(_ value: Double) -> String {
        guard value.isFinite else { return "#NUM!" }
        if value.rounded() == value, value.magnitude < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.12g", value)
        if text.contains("e") || text.contains("E") { return text }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    /// A serial number as an ISO-8601 date, date-time, or time.
    public static func temporal(
        _ serial: Double,
        kind: NumberFormat.Kind,
        system: DateSystem
    ) -> String? {
        let parts = SerialDate.components(serial: serial, system: system)
        let date = String(
            format: "%04d-%02d-%02d", parts.year, parts.month, parts.day
        )
        let time = parts.millisecond > 0
            ? String(format: "%02d:%02d:%02d.%03d", parts.hour, parts.minute, parts.second, parts.millisecond)
            : String(format: "%02d:%02d:%02d", parts.hour, parts.minute, parts.second)
        switch kind {
        case .time: return time
        case .dateTime: return "\(date)T\(time)"
        case .date: return date
        default: return nil
        }
    }

    /// A count with thousands separators, for prose in a tool result.
    public static func count(_ value: Int) -> String {
        var digits = String(abs(value))
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits.removeLast(3)
        }
        grouped = digits + grouped
        return value < 0 ? "-" + grouped : grouped
    }

    /// A cell's formula with the leading `=` an agent expects, or `nil`.
    ///
    /// Formulas are stored without the `=` — that is how OOXML spells them — and an agent that
    /// round-trips one back into `write_range` should get the same formula, so it is added
    /// here and stripped on the way in.
    public static func formula(_ cell: Cell) -> String? {
        guard let formula = cell.formula else { return nil }
        return formula.hasPrefix("=") ? formula : "=" + formula
    }
}
