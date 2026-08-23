import Foundation

/// Excel's numeric semantics, which are IEEE 754 doubles plus two deliberate lies.
///
/// **Lie one: 15 significant digits.** Excel stores a full double but never shows you more
/// than 15 significant decimal digits, and its equality comparisons in the UI behave as if the
/// extra bits were not there. Two results that differ only past the 15th digit are the same
/// number as far as a user — or a fixture sidecar — is concerned.
///
/// **Lie two: cosmetic zero.** `=0.1+0.2-0.3` shows `0`, not `5.5511151231257827E-17`. Excel
/// special-cases the *final* addition or subtraction of a formula: when the result is
/// vanishingly small relative to its operands, it is snapped to zero. Without this, every
/// spreadsheet that subtracts two currency columns eventually shows a stray `-1.42e-14` and
/// the user concludes the program is broken.
///
/// Both are applied here rather than scattered through the function table, so there is exactly
/// one place to look when a number is one ulp off.
public enum ExcelNumber {
    /// Significant decimal digits Excel keeps.
    public static let significantDigits = 15

    /// Relative threshold below which the result of a `+`/`-` collapses to zero.
    ///
    /// `2^-49 ≈ 1.78e-15`. Chosen to sit above the largest error a single cancelling
    /// addition of two doubles can leave behind (about 1.1e-16 relative) and comfortably below
    /// a difference a user could have meant: `=1-0.99999999999999` still gives `1e-14`, which
    /// is what Excel shows.
    public static let cancellationEpsilon = 0x1p-49

    /// `a + b`, with cancellation snapped to zero.
    public static func add(_ lhs: Double, _ rhs: Double) -> Double {
        snapCancellation(lhs + rhs, lhs, rhs)
    }

    /// `a - b`, with cancellation snapped to zero.
    public static func subtract(_ lhs: Double, _ rhs: Double) -> Double {
        snapCancellation(lhs - rhs, lhs, rhs)
    }

    /// Sums a sequence the way `SUM` does, snapping the running total's cancellation.
    ///
    /// Applied per step rather than once at the end because that is where the noise is
    /// introduced; a column of `0.1`s that sums to `0.9999999999999999` becomes `1`.
    public static func sum(_ values: some Sequence<Double>) -> Double {
        var total = 0.0
        for value in values {
            total = add(total, value)
        }
        return total
    }

    /// The zero-snap itself. Exposed so tests can pin the boundary.
    public static func snapCancellation(_ result: Double, _ lhs: Double, _ rhs: Double) -> Double {
        guard result != 0, result.isFinite else { return result }
        let magnitude = Swift.max(abs(lhs), abs(rhs))
        guard magnitude > 0, abs(result) < magnitude * cancellationEpsilon else { return result }
        return 0
    }

    /// `value` rounded to 15 significant decimal digits.
    ///
    /// This is the number Excel *shows*. Use it when comparing a computed result against a
    /// value a human or another engine wrote down, never as a step inside an accumulation —
    /// rounding intermediates would make `SUM` depend on argument order.
    public static func round15(_ value: Double) -> Double {
        roundToSignificantDigits(value, significantDigits)
    }

    /// `value` rounded to `digits` significant decimal digits.
    public static func roundToSignificantDigits(_ value: Double, _ digits: Int) -> Double {
        guard value.isFinite, value != 0, digits > 0, digits < 18 else { return value }
        let exponent = Int(floor(log10(abs(value))))
        let shift = digits - 1 - exponent
        // Beyond ±307 the scaling itself overflows or flushes to zero, and a number that
        // extreme has no digits left to lose anyway.
        guard shift > -300, shift < 300 else { return value }
        let scale = pow(10.0, Double(shift))
        let scaled = (value * scale).rounded(.toNearestOrAwayFromZero)
        guard scaled.isFinite else { return value }
        return scaled / scale
    }

    /// The value to persist for a computed number: cosmetic rounding applied, `-0` normalised
    /// to `0`, and non-finite results turned into the error Excel would have produced.
    ///
    /// Kept separate from ``round15(_:)`` so the caller can see that storing is the moment the
    /// lie is told.
    public static func store(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let rounded = round15(value)
        return rounded == 0 ? 0 : rounded
    }

    /// Whether two numbers are the same to Excel: equal after 15-digit rounding.
    ///
    /// This is the comparison the `functions.tsv` table test uses, because the expectations in
    /// it were written by humans and by other engines, both of which round to 15 digits.
    public static func equal(_ lhs: Double, _ rhs: Double) -> Bool {
        if lhs == rhs { return true }
        if lhs.isNaN || rhs.isNaN { return false }
        if !lhs.isFinite || !rhs.isFinite { return false }
        return round15(lhs) == round15(rhs)
    }

    /// Turns a non-finite arithmetic result into Excel's error for it.
    ///
    /// Excel has no infinity and no NaN: overflow is `#NUM!`, and so is `0/0` where it is not
    /// already `#DIV/0!`.
    public static func checked(_ value: Double) -> ScalarValue {
        value.isFinite ? .number(value) : .error(.invalidNumber)
    }

    // MARK: - Text form

    /// A number rendered the way Excel's `General` format renders it, which is also the
    /// spelling `=A1&""` produces.
    ///
    /// Not a full number-format implementation — that is A4's `NumberFormat`. This covers the
    /// one case the formula engine owns: number-to-text coercion inside `&`, `CONCAT`, and
    /// friends, where Excel uses up to 15 significant digits with no thousands separator and
    /// scientific notation outside `1e-5 ..< 1e11`.
    public static func generalText(_ value: Double) -> String {
        guard value.isFinite else { return "#NUM!" }
        if value == 0 { return "0" }
        let rounded = round15(value)
        let magnitude = abs(rounded)
        if magnitude >= 1e11 || magnitude < 1e-5 {
            return scientificText(rounded)
        }
        // %.15g is exactly "15 significant digits, shortest form", which is General's rule.
        var text = String(format: "%.15g", rounded)
        if text.contains("e") || text.contains("E") {
            text = scientificText(rounded)
        }
        return text
    }

    private static func scientificText(_ value: Double) -> String {
        var text = String(format: "%.14E", value)
        // Trim the mantissa's trailing zeros: 1.00000000000000E+15 → 1E+15.
        if let eIndex = text.firstIndex(where: { $0 == "E" }) {
            var mantissa = String(text[text.startIndex ..< eIndex])
            let exponent = String(text[eIndex...])
            while mantissa.contains("."), mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            text = mantissa + exponent
        }
        return text
    }
}
