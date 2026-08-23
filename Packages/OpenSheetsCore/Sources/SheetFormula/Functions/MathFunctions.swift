import Foundation
import SheetModel

/// Arithmetic, rounding, and trigonometry.
///
/// The error kinds here are Excel's, not LibreOffice's, and they differ:
/// `SQRT(-1)` is `#NUM!` in Excel and `#VALUE!` in LibreOffice (WAVE-1-ADDENDUM §4). Every
/// domain failure below — negative roots, logs of non-positive numbers, a fractional power of
/// a negative base, factorials that overflow — is `#NUM!`.
enum MathFunctions {
    static var signatures: [FunctionSignature] { core + rounding + trigonometry }

    // MARK: - Core arithmetic

    private static let core: [FunctionSignature] = [
        FunctionSignature("SUM", 1, .max) { call in
            .number(ExcelNumber.sum(try call.numbers(from: 0)))
        },
        FunctionSignature("PRODUCT", 1, .max) { call in
            let values = try call.numbers(from: 0)
            guard !values.isEmpty else { return .number(0) }
            return .scalar(ExcelNumber.checked(values.reduce(1, *)))
        },
        FunctionSignature("SUMSQ", 1, .max) { call in
            .number(ExcelNumber.sum(try call.numbers(from: 0).map { $0 * $0 }))
        },
        FunctionSignature("ABS", 1, 1) { call in .number(abs(try call.number(0))) },
        FunctionSignature("SIGN", 1, 1) { call in
            let value = try call.number(0)
            return .number(value > 0 ? 1 : (value < 0 ? -1 : 0))
        },
        FunctionSignature("SQRT", 1, 1) { call in
            let value = try call.number(0)
            // Excel: `#NUM!`. LibreOffice: `#VALUE!`. We follow Excel.
            guard value >= 0 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(value.squareRoot())
        },
        FunctionSignature("POWER", 2, 2) { call in
            try .scalar(MathFunctions.power(try call.number(0), try call.number(1)))
        },
        FunctionSignature("EXP", 1, 1) { call in .scalar(ExcelNumber.checked(exp(try call.number(0)))) },
        FunctionSignature("LN", 1, 1) { call in
            let value = try call.number(0)
            guard value > 0 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(log(value))
        },
        FunctionSignature("LOG10", 1, 1) { call in
            let value = try call.number(0)
            guard value > 0 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(log10(value))
        },
        FunctionSignature("LOG", 1, 2) { call in
            let value = try call.number(0)
            let base = try call.number(1, default: 10)
            guard value > 0, base > 0, base != 1 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(log(value) / log(base))
        },
        FunctionSignature("MOD", 2, 2) { call in
            let dividend = try call.number(0)
            let divisor = try call.number(1)
            guard divisor != 0 else { throw FormulaFault.cell(.divideByZero) }
            // Excel's MOD takes the sign of the divisor: MOD(-3,2) is 1, not -1.
            let remainder = dividend.truncatingRemainder(dividingBy: divisor)
            return .number(remainder != 0 && (remainder < 0) != (divisor < 0) ? remainder + divisor : remainder)
        },
        FunctionSignature("QUOTIENT", 2, 2) { call in
            let divisor = try call.number(1)
            guard divisor != 0 else { throw FormulaFault.cell(.divideByZero) }
            return .number((try call.number(0) / divisor).rounded(.towardZero))
        },
        FunctionSignature("GCD", 1, .max) { call in
            let values = try MathFunctions.nonNegativeIntegers(call)
            return .number(Double(values.reduce(0) { MathFunctions.greatestCommonDivisor($0, $1) }))
        },
        FunctionSignature("LCM", 1, .max) { call in
            let values = try MathFunctions.nonNegativeIntegers(call)
            var result = 1
            for value in values {
                if value == 0 { return .number(0) }
                let divisor = MathFunctions.greatestCommonDivisor(result, value)
                let (product, overflow) = (result / divisor).multipliedReportingOverflow(by: value)
                guard !overflow else { throw FormulaFault.cell(.invalidNumber) }
                result = product
            }
            return .number(Double(result))
        },
        FunctionSignature("FACT", 1, 1) { call in
            let value = try call.integer(0)
            guard value >= 0, value <= 170 else { throw FormulaFault.cell(.invalidNumber) }
            return .scalar(ExcelNumber.checked((0 ..< value).reduce(1.0) { $0 * Double($1 + 1) }))
        },
        FunctionSignature("PI", 0, 0) { _ in .number(Double.pi) },
        FunctionSignature("RAND", 0, 0, volatile: true) { call in .number(call.scope.nextRandom()) },
        FunctionSignature("RANDBETWEEN", 2, 2, volatile: true) { call in
            let low = try call.integer(0)
            let high = try call.integer(1)
            guard low <= high else { throw FormulaFault.cell(.invalidNumber) }
            let span = Double(high - low + 1)
            return .number(Double(low) + (call.scope.nextRandom() * span).rounded(.down))
        },
    ]

    // MARK: - Rounding

    private static let rounding: [FunctionSignature] = [
        FunctionSignature("ROUND", 2, 2) { call in
            .scalar(ExcelNumber.checked(MathFunctions.scaled(
                try call.number(0), try call.integer(1), rule: .toNearestOrAwayFromZero
            )))
        },
        FunctionSignature("ROUNDUP", 2, 2) { call in
            .scalar(ExcelNumber.checked(MathFunctions.scaled(try call.number(0), try call.integer(1), rule: .awayFromZero)))
        },
        FunctionSignature("ROUNDDOWN", 2, 2) { call in
            .scalar(ExcelNumber.checked(MathFunctions.scaled(try call.number(0), try call.integer(1), rule: .towardZero)))
        },
        FunctionSignature("INT", 1, 1) { call in .number((try call.number(0)).rounded(.down)) },
        FunctionSignature("TRUNC", 1, 2) { call in
            .scalar(ExcelNumber.checked(MathFunctions.scaled(try call.number(0), try call.integer(1, default: 0), rule: .towardZero)))
        },
        FunctionSignature("EVEN", 1, 1) { call in .number(MathFunctions.toParity(try call.number(0), even: true)) },
        FunctionSignature("ODD", 1, 1) { call in .number(MathFunctions.toParity(try call.number(0), even: false)) },
        FunctionSignature("CEILING", 2, 2) { call in
            let value = try call.number(0)
            let step = try call.number(1)
            // Excel returns 0 for a zero significance here but `#DIV/0!` from FLOOR. Not a
            // typo on our side: the two functions genuinely disagree.
            if step == 0 { return .number(0) }
            guard !(value > 0 && step < 0) else { throw FormulaFault.cell(.invalidNumber) }
            // Positive number: up. Negative number with positive step: toward zero.
            let rule: FloatingPointRoundingRule = value < 0 && step > 0 ? .up : .awayFromZero
            return .scalar(ExcelNumber.checked((value / step).rounded(rule) * step))
        },
        FunctionSignature("FLOOR", 2, 2) { call in
            let value = try call.number(0)
            let step = try call.number(1)
            guard step != 0 else { throw FormulaFault.cell(.divideByZero) }
            guard !(value > 0 && step < 0) else { throw FormulaFault.cell(.invalidNumber) }
            let rule: FloatingPointRoundingRule = value < 0 && step > 0 ? .down : .towardZero
            return .scalar(ExcelNumber.checked((value / step).rounded(rule) * step))
        },
        FunctionSignature("MROUND", 2, 2) { call in
            let value = try call.number(0)
            let step = try call.number(1)
            if step == 0 { return .number(0) }
            guard (value >= 0) == (step >= 0) else { throw FormulaFault.cell(.invalidNumber) }
            return .scalar(ExcelNumber.checked((value / step).rounded(.toNearestOrAwayFromZero) * step))
        },
    ]

    // MARK: - Trigonometry

    private static let trigonometry: [FunctionSignature] = [
        FunctionSignature("SIN", 1, 1) { call in .number(sin(try call.number(0))) },
        FunctionSignature("COS", 1, 1) { call in .number(cos(try call.number(0))) },
        FunctionSignature("TAN", 1, 1) { call in .scalar(ExcelNumber.checked(tan(try call.number(0)))) },
        FunctionSignature("ASIN", 1, 1) { call in
            let value = try call.number(0)
            guard value >= -1, value <= 1 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(asin(value))
        },
        FunctionSignature("ACOS", 1, 1) { call in
            let value = try call.number(0)
            guard value >= -1, value <= 1 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(acos(value))
        },
        FunctionSignature("ATAN", 1, 1) { call in .number(atan(try call.number(0))) },
        FunctionSignature("ATAN2", 2, 2) { call in
            let x = try call.number(0)
            let y = try call.number(1)
            guard x != 0 || y != 0 else { throw FormulaFault.cell(.divideByZero) }
            // Excel's argument order is (x, y), the reverse of C's atan2.
            return .number(atan2(y, x))
        },
        FunctionSignature("DEGREES", 1, 1) { call in .number(try call.number(0) * 180 / Double.pi) },
        FunctionSignature("RADIANS", 1, 1) { call in .number(try call.number(0) * Double.pi / 180) },
    ]

    // MARK: - Shared arithmetic

    /// `x^y` with Excel's domain rules: a negative base needs an integral exponent, and `0^0`
    /// is `1` rather than `#NUM!`.
    static func power(_ base: Double, _ exponent: Double) throws -> ScalarValue {
        if base == 0, exponent < 0 { throw FormulaFault.cell(.divideByZero) }
        if base < 0, exponent != exponent.rounded(.towardZero) { throw FormulaFault.cell(.invalidNumber) }
        let result = pow(base, exponent)
        guard result.isFinite else { throw FormulaFault.cell(.invalidNumber) }
        return .number(result)
    }

    /// Rounds `value` at `digits` decimal places. Negative digits round to tens, hundreds, …
    static func scaled(_ value: Double, _ digits: Int, rule: FloatingPointRoundingRule) -> Double {
        guard value.isFinite else { return value }
        guard digits > -300, digits < 300 else { return digits >= 0 ? value : 0 }
        let scale = pow(10.0, Double(digits))
        let scaled = value * scale
        guard scaled.isFinite else { return value }
        return scaled.rounded(rule) / scale
    }

    private static func toParity(_ value: Double, even: Bool) -> Double {
        if value == 0 { return even ? 0 : 1 }
        let step = 2.0
        let magnitude = abs(value)
        let offset = even ? 0.0 : 1.0
        let rounded = ((magnitude - offset) / step).rounded(.up) * step + offset
        return value < 0 ? -rounded : rounded
    }

    private static func nonNegativeIntegers(_ call: FunctionCallSite) throws -> [Int] {
        try call.numbers(from: 0).map { value in
            guard value >= 0, value < 9.007e15 else { throw FormulaFault.cell(.invalidNumber) }
            return Int(value.rounded(.towardZero))
        }
    }

    static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = abs(lhs)
        var b = abs(rhs)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
