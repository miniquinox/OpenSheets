import Foundation
import SheetModel

/// The outcome of a coercion: a value, or the Excel error that coercion produced.
///
/// Not `Result<Value, CellError>`, because ``CellError`` is a plain token in the frozen model
/// and does not conform to `Error` — and should not. An error *token* is a value a cell holds,
/// not a control-flow event; conforming it to `Error` would invite `throw CellError.wrongType`
/// at call sites where the right answer is to return it.
public enum Coerced<Value>: Sendable where Value: Sendable {
    case success(Value)
    case failure(CellError)

    /// The value, or `nil` when this is a failure.
    public var value: Value? { if case let .success(value) = self { value } else { nil } }

    /// The error, or `nil` when this succeeded.
    public var error: CellError? { if case let .failure(error) = self { error } else { nil } }

    /// Transforms the value, carrying any failure through.
    public func map<Transformed>(_ transform: (Value) -> Transformed) -> Coerced<Transformed> {
        switch self {
        case let .success(value): .success(transform(value))
        case let .failure(error): .failure(error)
        }
    }
}

/// Excel's type-conversion rules, which are not Swift's and not anybody else's.
///
/// The three that catch people out, all encoded here:
///
/// - **Text is a number when you do arithmetic with it, and not when you compare with it.**
///   `="42"+1` is `43`; `="42"=42` is `FALSE`. There is no single "is this text a number"
///   answer, only a per-context one.
/// - **Blank is zero, except when it is the empty string.** `=A1+1` on an empty `A1` is `1`;
///   `=A1&"x"` is `"x"`; `=A1=""` is `TRUE` *and* `=A1=0` is `TRUE`, which is inconsistent and
///   is nevertheless what Excel does.
/// - **Booleans are numbers in arithmetic and are ranked above text in comparison.**
///   `=TRUE+1` is `2`, and `=TRUE>"zzz"` is `TRUE`.
public enum Coercion {
    // MARK: - To number

    /// Excel's arithmetic coercion: what `+`, `-`, `*`, `/`, `^`, `%` and unary minus do to an
    /// operand before touching it.
    ///
    /// Returns a `ScalarValue` rather than a `Double?` so the caller propagates the *right*
    /// error: `#VALUE!` for unparseable text, and the original error for an error operand.
    public static func arithmeticNumber(_ value: ScalarValue, dateSystem: DateSystem) -> Coerced<Double> {
        switch value {
        case .blank:
            .success(0)
        case let .number(number):
            .success(number)
        case let .boolean(flag):
            .success(flag ? 1 : 0)
        case let .text(text):
            if let number = number(fromText: text, dateSystem: dateSystem) {
                .success(number)
            } else {
                .failure(.wrongType)
            }
        case let .error(error):
            .failure(error)
        }
    }

    /// Coercion for a value that arrived through a *reference* into an aggregate such as
    /// `SUM` or `AVERAGE`.
    ///
    /// The difference from ``arithmeticNumber(_:dateSystem:)`` is the whole reason this
    /// function exists: `=SUM("42")` is `42`, but `=SUM(A1)` where `A1` holds the text `42` is
    /// `0`. Text and booleans reached through a reference are **skipped**, not coerced —
    /// otherwise a column with a stray header would silently change every total.
    ///
    /// `nil` means "not a number, skip me".
    public static func aggregateNumber(_ value: ScalarValue) -> Coerced<Double?> {
        switch value {
        case .blank, .text, .boolean:
            .success(Double?.none)
        case let .number(number):
            .success(number)
        case let .error(error):
            .failure(error)
        }
    }

    /// Parses text the way Excel does when it needs a number out of a string.
    ///
    /// Accepts a leading sign, `(1.5)` for negatives, a `%` suffix, `1e6` scientific form,
    /// ASCII group separators, a leading currency sign, ISO dates, and `hh:mm[:ss]` times.
    /// Rejects everything else — including the empty string, which is `#VALUE!` in arithmetic
    /// even though a *blank cell* is zero.
    public static func number(fromText text: String, dateSystem: DateSystem) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let plain = plainNumber(fromText: trimmed) { return plain }
        if let serial = dateSerial(fromText: trimmed, dateSystem: dateSystem) { return serial }
        return nil
    }

    /// The numeric half of ``number(fromText:dateSystem:)``, with no date handling.
    static func plainNumber(fromText text: String) -> Double? {
        var body = Substring(text)
        var sign = 1.0
        var percentScale = 1.0

        if body.hasPrefix("("), body.hasSuffix(")"), body.count >= 3 {
            sign = -1
            body = body.dropFirst().dropLast()
            body = body.trimmingPrefix(while: { $0 == " " })
        }
        if body.hasPrefix("-") {
            sign *= -1
            body = body.dropFirst()
        } else if body.hasPrefix("+") {
            body = body.dropFirst()
        }
        // One leading currency mark, which is how a pasted "$1,234.50" survives.
        if let first = body.first, first == "$" || first == "£" || first == "€" || first == "¥" {
            body = body.dropFirst()
        }
        if body.hasSuffix("%") {
            percentScale = 0.01
            body = body.dropLast()
        }
        body = body.trimmingCharacters(in: .whitespaces)[...]
        guard !body.isEmpty else { return nil }

        var digits = ""
        digits.reserveCapacity(body.count)
        var sawDigit = false
        var sawDot = false
        var sawExponent = false
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            switch character {
            case "0" ... "9":
                sawDigit = true
                digits.append(character)
            case ",":
                // A group separator only ever sits between digits.
                guard sawDigit, !sawDot, !sawExponent else { return nil }
            case ".":
                guard !sawDot, !sawExponent else { return nil }
                sawDot = true
                digits.append(character)
            case "e", "E":
                guard sawDigit, !sawExponent else { return nil }
                sawExponent = true
                digits.append("e")
                let next = body.index(after: index)
                if next < body.endIndex, body[next] == "+" || body[next] == "-" {
                    digits.append(body[next])
                    index = next
                }
            default:
                return nil
            }
            index = body.index(after: index)
        }
        guard sawDigit, let value = Double(digits) else { return nil }
        return sign * value * percentScale
    }

    /// ISO-ish dates and clock times, which Excel coerces to serials.
    ///
    /// Only unambiguous spellings are accepted. `03/04/2024` is deliberately **not** parsed:
    /// it is March 4th in one locale and April 3rd in another, and guessing wrong silently is
    /// worse than `#VALUE!`.
    static func dateSerial(fromText text: String, dateSystem: DateSystem) -> Double? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first else { return nil }

        if let date = isoDate(String(head), dateSystem: dateSystem) {
            guard parts.count == 2 else { return date }
            guard let time = clockTime(String(parts[1])) else { return nil }
            return date + time
        }
        guard parts.count == 1 else { return nil }
        return clockTime(String(head))
    }

    private static func isoDate(_ text: String, dateSystem: DateSystem) -> Double? {
        let separator: Character = text.contains("-") ? "-" : "/"
        let fields = text.split(separator: separator)
        guard fields.count == 3,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              fields[0].count == 4
        else { return nil }
        return SerialDate.serial(year: year, month: month, day: day, system: dateSystem)
    }

    private static func clockTime(_ text: String) -> Double? {
        let fields = text.split(separator: ":")
        guard fields.count == 2 || fields.count == 3,
              let hour = Int(fields[0]), let minute = Int(fields[1]),
              hour >= 0, minute >= 0, minute < 60
        else { return nil }
        var seconds = 0.0
        if fields.count == 3 {
            guard let value = Double(fields[2]), value >= 0, value < 60 else { return nil }
            seconds = value
        }
        return (Double(hour) * 3600 + Double(minute) * 60 + seconds) / 86_400
    }

    // MARK: - To text

    /// What `&` and the text functions see.
    ///
    /// A blank becomes `""`, a boolean becomes `TRUE`/`FALSE` in capitals, and a number gets
    /// the `General` spelling — 15 significant digits, no separators.
    public static func text(_ value: ScalarValue) -> Coerced<String> {
        switch value {
        case .blank: .success("")
        case let .number(number): .success(ExcelNumber.generalText(number))
        case let .text(text): .success(text)
        case let .boolean(flag): .success(flag ? "TRUE" : "FALSE")
        case let .error(error): .failure(error)
        }
    }

    // MARK: - To boolean

    /// What `IF`, `AND`, `NOT` and friends see.
    ///
    /// Numbers are false only at zero. Text is **not** coercible — `=IF("TRUE",1,0)` is
    /// `#VALUE!` in Excel, which surprises people but is the rule.
    public static func boolean(_ value: ScalarValue) -> Coerced<Bool> {
        switch value {
        case .blank: .success(false)
        case let .number(number): .success(number != 0)
        case let .boolean(flag): .success(flag)
        case .text: .failure(.wrongType)
        case let .error(error): .failure(error)
        }
    }

    // MARK: - Comparison

    /// Excel's ordering across mixed types, as a three-way result.
    ///
    /// Within a type: numbers numerically, text case-insensitively by Unicode order, booleans
    /// with `FALSE < TRUE`. Across types the ranking is **number < text < boolean**, which is
    /// why `=1<"a"` and `="z"<TRUE` are both `TRUE`.
    ///
    /// A blank takes the identity of whatever it is compared against — `0`, `""`, or `FALSE` —
    /// so `=A1=0` and `=A1=""` are both `TRUE` for an empty `A1`.
    public static func compare(_ lhs: ScalarValue, _ rhs: ScalarValue) -> Coerced<Int> {
        if let error = lhs.errorValue { return .failure(error) }
        if let error = rhs.errorValue { return .failure(error) }

        let left = resolveBlank(lhs, against: rhs)
        let right = resolveBlank(rhs, against: lhs)

        switch (left, right) {
        case let (.number(a), .number(b)):
            return .success(a < b ? -1 : (a > b ? 1 : 0))
        case let (.text(a), .text(b)):
            return .success(orderText(a, b))
        case let (.boolean(a), .boolean(b)):
            return .success(a == b ? 0 : (a ? 1 : -1))
        default:
            let a = left.comparisonRank
            let b = right.comparisonRank
            return .success(a < b ? -1 : (a > b ? 1 : 0))
        }
    }

    /// Two blanks compare equal; a blank against anything else takes that thing's type.
    private static func resolveBlank(_ value: ScalarValue, against other: ScalarValue) -> ScalarValue {
        guard case .blank = value else { return value }
        switch other {
        case .text: return .text("")
        case .boolean: return .boolean(false)
        default: return .number(0)
        }
    }

    /// Excel compares text case-insensitively and without locale collation.
    ///
    /// Case-insensitive is the surprising half: `="a"="A"` is `TRUE`, and `VLOOKUP` finds
    /// `"Total"` when you ask for `"TOTAL"`. Comparison folds case but the *ordering* is then
    /// plain Unicode scalar order, which is what makes it deterministic across machines —
    /// a locale-aware collation would make the same workbook sort differently in Turkey.
    public static func orderText(_ lhs: String, _ rhs: String) -> Int {
        let a = lhs.uppercased()
        let b = rhs.uppercased()
        if a == b { return 0 }
        return a < b ? -1 : 1
    }

    /// Whether two scalars are equal under Excel's `=` operator.
    public static func equals(_ lhs: ScalarValue, _ rhs: ScalarValue) -> Coerced<Bool> {
        compare(lhs, rhs).map { $0 == 0 }
    }
}
