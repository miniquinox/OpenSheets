//
//  XLSXEscape.swift
//  SheetFormat
//
//  Turning model values into XML text that Excel will actually open.
//

import Foundation
import SheetModel

/// Escaping for the XML the writer emits.
///
/// Three separate jobs live here and conflating them is how a writer produces a file that
/// opens everywhere except the one place that matters:
///
/// 1. **Markup escaping** — `&`, `<`, `>` in text; additionally `"` and the whitespace
///    characters in attribute values, because an unescaped newline inside an attribute is
///    normalised to a space by every conforming parser and the value silently changes.
/// 2. **XML 1.0 legality** — a NUL, a BEL, a vertical tab are *not representable* in XML 1.0
///    at all, escaped or otherwise. They arrive constantly from CSV imports and from
///    databases, and writing one produces a file Excel calls corrupt.
/// 3. **Number formatting** — `<v>` has to round-trip a `Double` bit-for-bit, and has to do it
///    without printing `1.0` where every other producer prints `1`.
public enum XLSXEscape {
    /// What to do with characters XML 1.0 cannot represent.
    public enum ControlCharacterPolicy: String, Sendable, Hashable, CaseIterable {
        /// Rewrite as `_xHHHH_`, which is what Excel itself does and what a reader that knows
        /// the convention turns back into the original character. Lossless.
        case escape
        /// Drop them. Lossy, but produces text no reader can misinterpret.
        case strip
        /// Refuse to write. For callers who would rather fail than change the user's data.
        case reject
    }

    // MARK: - Markup

    /// Escapes a text node.
    ///
    /// `>` is escaped even though it is only strictly required inside `]]>`, because producers
    /// vary and a `>` inside cell text is the kind of thing that turns up in one customer's
    /// file and nobody else's.
    public static func text(_ value: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(value.count + 8)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Escapes an attribute value, including the whitespace an XML parser would otherwise
    /// normalise away.
    public static func attribute(_ value: some StringProtocol) -> String {
        var result = ""
        result.reserveCapacity(value.count + 8)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: - XML 1.0 legality

    /// Whether `scalar` is one XML 1.0 permits in character data.
    ///
    /// Tab, line feed and carriage return are legal; every other C0 control is not, and neither
    /// are the surrogate range, `U+FFFE` and `U+FFFF`.
    public static func isLegalXMLCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0D: true
        case 0x20 ... 0xD7FF: true
        case 0xE000 ... 0xFFFD: true
        case 0x1_0000 ... 0x10_FFFF: true
        default: false
        }
    }

    /// Whether `value` holds anything XML 1.0 cannot represent.
    public static func containsIllegalCharacters(_ value: some StringProtocol) -> Bool {
        value.unicodeScalars.contains { !isLegalXMLCharacter($0) }
    }

    /// Applies `policy` to `value`, returning text that is safe to escape and emit.
    ///
    /// The `_xHHHH_` convention has a trap: text that *already* contains the literal sequence
    /// `_x0041_` would decode back as `A`. Excel's answer, which this follows, is to escape the
    /// underscore of any such sequence as `_x005F_` so decoding is unambiguous in both
    /// directions. That rewrite happens only when the sequence is actually present, so ordinary
    /// text is never touched.
    public static func sanitiseCellText(
        _ value: String,
        policy: ControlCharacterPolicy,
        ref: String
    ) throws(SheetError) -> String {
        let hasIllegal = containsIllegalCharacters(value)
        let hasEscapeLookalike = policy == .escape && containsUnderscoreEscapeSequence(value)
        guard hasIllegal || hasEscapeLookalike else { return value }

        switch policy {
        case .reject:
            throw SheetError.invalidArgument(
                name: ref,
                reason: "the text contains a character XML 1.0 cannot represent"
            )
        case .strip:
            var result = String.UnicodeScalarView()
            for scalar in value.unicodeScalars where isLegalXMLCharacter(scalar) {
                result.append(scalar)
            }
            return String(result)
        case .escape:
            var result = ""
            result.reserveCapacity(value.count + 16)
            let scalars = Array(value.unicodeScalars)
            var index = 0
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "_", isUnderscoreEscapeSequence(scalars, at: index) {
                    result += "_x005F_"
                    index += 1
                    continue
                }
                if isLegalXMLCharacter(scalar) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += String(format: "_x%04X_", scalar.value)
                }
                index += 1
            }
            return result
        }
    }

    /// Whether `scalars[index...]` is `_xHHHH_`.
    private static func isUnderscoreEscapeSequence(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 6 < scalars.count else { return false }
        guard scalars[index] == "_", scalars[index + 1] == "x", scalars[index + 6] == "_" else { return false }
        return (2 ... 5).allSatisfy { offset in
            let value = scalars[index + offset].value
            return (0x30 ... 0x39).contains(value) || (0x41 ... 0x46).contains(value) || (0x61 ... 0x66).contains(value)
        }
    }

    private static func containsUnderscoreEscapeSequence(_ value: some StringProtocol) -> Bool {
        let scalars = Array(value.unicodeScalars)
        for index in scalars.indices where isUnderscoreEscapeSequence(scalars, at: index) {
            return true
        }
        return false
    }

    // MARK: - Numbers

    /// A `Double` as `<v>` wants it: shortest form that reads back identically.
    ///
    /// Integral values print without a fractional part, because that is what every other
    /// producer writes and a diff against an Excel-written file should not light up over
    /// `42` versus `42.0`. Beyond 2^53 the integral shortcut stops being exact, so the
    /// shortest-round-trip description takes over.
    public static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return "\(value)"
    }
}
