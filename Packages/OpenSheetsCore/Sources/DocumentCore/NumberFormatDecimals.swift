import Foundation
import SheetModel

/// Adds and removes decimal places on an existing number format.
///
/// The toolbar's two most-used buttons after bold. They have to operate on the *cell's own* format
/// code rather than swap in a preset: a column reading `$#,##0.00` must become `$#,##0.000`, and a
/// preset would take the currency symbol and the grouping with it — which is not what "one more
/// decimal place" means to anyone.
///
/// Every section of a multi-section code is adjusted together (`positive;negative;zero;text`),
/// because a code whose positive branch shows two decimals and whose negative branch shows three
/// is a code nobody wrote on purpose.
public enum NumberFormatDecimals {
    /// The most decimal places any of this format's numeric sections shows.
    public static func decimalPlaces(of format: NumberFormat) -> Int {
        sections(of: format.formatCode)
            .map { count(in: $0) }
            .max() ?? 0
    }

    /// `nil` when the change would be a no-op — removing a decimal from an integer format, or
    /// adding a twelfth, which Excel also refuses.
    public static func adjusting(_ format: NumberFormat, by delta: Int) -> NumberFormat? {
        let code = format.isGeneral ? "0" : format.formatCode
        guard !code.isEmpty, format.kind != .text else { return nil }
        // A date format has no decimal places to add; adding one to `d mmm yy` would corrupt it.
        guard !format.isDateTime else { return nil }

        let adjusted = sections(of: code)
            .map { adjust($0, by: delta) }
            .joined(separator: ";")
        guard adjusted != code else { return nil }
        return NumberFormat(adjusted)
    }

    private static func sections(of code: String) -> [String] {
        code.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    }

    /// The digits after the first unquoted `.` in a section.
    private static func count(in section: String) -> Int {
        guard let dot = fractionStart(section) else { return 0 }
        var digits = 0
        var index = dot
        while index < section.endIndex, section[index] == "0" || section[index] == "#" {
            digits += 1
            index = section.index(after: index)
        }
        return digits
    }

    private static func fractionStart(_ section: String) -> String.Index? {
        var quoted = false
        var index = section.startIndex
        while index < section.endIndex {
            let character = section[index]
            if character == "\"" { quoted.toggle() }
            if character == "\\" {
                index = section.index(after: index)
                if index < section.endIndex { index = section.index(after: index) }
                continue
            }
            if character == ".", !quoted {
                return section.index(after: index)
            }
            index = section.index(after: index)
        }
        return nil
    }

    private static func adjust(_ section: String, by delta: Int) -> String {
        guard !section.isEmpty else { return section }
        let current = count(in: section)
        let wanted = max(0, min(11, current + delta))
        guard wanted != current else { return section }

        if let start = fractionStart(section) {
            var end = start
            while end < section.endIndex, section[end] == "0" || section[end] == "#" {
                end = section.index(after: end)
            }
            let dot = section.index(before: start)
            if wanted == 0 {
                return String(section[section.startIndex ..< dot]) + String(section[end...])
            }
            return String(section[section.startIndex ..< start])
                + String(repeating: "0", count: wanted)
                + String(section[end...])
        }

        guard wanted > 0 else { return section }
        // No fraction yet: insert one after the last integer placeholder, so `$#,##0` becomes
        // `$#,##0.0` and the trailing `_)` of an accounting format stays where it is.
        guard let last = section.lastIndex(where: { $0 == "0" || $0 == "#" }) else { return section }
        let insertion = section.index(after: last)
        return String(section[section.startIndex ..< insertion])
            + "." + String(repeating: "0", count: wanted)
            + String(section[insertion...])
    }
}
