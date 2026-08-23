import Foundation
import SheetModel

/// The time-value-of-money family.
///
/// # Sign conventions are not decoration
///
/// Excel's cash-flow sign rule is that money you pay out is negative and money you receive is
/// positive, and every function here inherits it from one equation:
///
/// ```
/// pv·(1+rate)^nper + pmt·(1 + rate·type)·((1+rate)^nper − 1)/rate + fv = 0
/// ```
///
/// `PMT`, `FV`, `PV` and `NPER` are that equation solved for each of its four unknowns, which
/// is why they are one private helper each rather than four independent formulas: an
/// implementation that derives them separately drifts, and the drift shows up as a loan
/// payment that is off by a cent — the kind of wrong number nobody catches by eye.
///
/// `type` is `0` for payments at the end of a period (the default) and `1` for the beginning.
///
/// Expected values in the corpus were checked against headless LibreOffice, which agrees with
/// Excel across this family.
enum FinancialFunctions {
    static var signatures: [FunctionSignature] { annuities + flows + depreciation }

    // MARK: - The annuity equation

    /// `(1+rate)^nper`, the growth factor every one of these needs.
    private static func growth(_ rate: Double, _ nper: Double) throws -> Double {
        let factor = pow(1 + rate, nper)
        guard factor.isFinite else { throw FormulaFault.cell(.invalidNumber) }
        return factor
    }

    /// The periodic payment. Negative for a loan taken out as a positive `pv`.
    static func payment(rate: Double, nper: Double, pv: Double, fv: Double, type: Double) throws -> Double {
        guard nper != 0 else { throw FormulaFault.cell(.invalidNumber) }
        guard rate != 0 else { return -(pv + fv) / nper }
        let factor = try growth(rate, nper)
        return -(pv * factor + fv) * rate / ((factor - 1) * (1 + rate * type))
    }

    /// The future value after `nper` periods.
    static func futureValue(rate: Double, nper: Double, pmt: Double, pv: Double, type: Double) throws -> Double {
        guard rate != 0 else { return -(pv + pmt * nper) }
        let factor = try growth(rate, nper)
        return -(pv * factor + pmt * (1 + rate * type) * (factor - 1) / rate)
    }

    /// The present value of `nper` payments plus a final `fv`.
    static func presentValue(rate: Double, nper: Double, pmt: Double, fv: Double, type: Double) throws -> Double {
        guard rate != 0 else { return -(fv + pmt * nper) }
        let factor = try growth(rate, nper)
        return -(fv + pmt * (1 + rate * type) * (factor - 1) / rate) / factor
    }

    /// How many periods it takes.
    static func periods(rate: Double, pmt: Double, pv: Double, fv: Double, type: Double) throws -> Double {
        guard rate != 0 else {
            guard pmt != 0 else { throw FormulaFault.cell(.invalidNumber) }
            return -(pv + fv) / pmt
        }
        let adjusted = pmt * (1 + rate * type)
        let numerator = adjusted - fv * rate
        let denominator = adjusted + pv * rate
        guard denominator != 0, numerator / denominator > 0 else { throw FormulaFault.cell(.invalidNumber) }
        return log(numerator / denominator) / log(1 + rate)
    }

    /// The interest portion of payment number `period`.
    ///
    /// Derived from the outstanding balance at the *start* of the period, which is the future
    /// value after `period − 1` payments. Splitting a payment any other way — apportioning by
    /// ratio, say — disagrees with every amortisation schedule a bank produces.
    static func interestPayment(
        rate: Double, period: Double, nper: Double, pv: Double, fv: Double, type: Double
    ) throws -> Double {
        guard period >= 1, period <= nper else { throw FormulaFault.cell(.invalidNumber) }
        let pmt = try payment(rate: rate, nper: nper, pv: pv, fv: fv, type: type)
        if period == 1, type == 1 { return 0 }
        let balance = try futureValue(rate: rate, nper: period - 1, pmt: pmt, pv: pv, type: type)
        let interest = balance * rate
        return type == 1 ? interest / (1 + rate) : interest
    }

    // MARK: - Signatures

    private static let annuities: [FunctionSignature] = [
        FunctionSignature("PMT", 3, 5) { call in
            .number(try payment(
                rate: try call.number(0), nper: try call.number(1), pv: try call.number(2),
                fv: try call.number(3, default: 0), type: try call.number(4, default: 0)
            ))
        },
        FunctionSignature("FV", 3, 5) { call in
            .number(try futureValue(
                rate: try call.number(0), nper: try call.number(1), pmt: try call.number(2),
                pv: try call.number(3, default: 0), type: try call.number(4, default: 0)
            ))
        },
        FunctionSignature("PV", 3, 5) { call in
            .number(try presentValue(
                rate: try call.number(0), nper: try call.number(1), pmt: try call.number(2),
                fv: try call.number(3, default: 0), type: try call.number(4, default: 0)
            ))
        },
        FunctionSignature("NPER", 3, 5) { call in
            .number(try periods(
                rate: try call.number(0), pmt: try call.number(1), pv: try call.number(2),
                fv: try call.number(3, default: 0), type: try call.number(4, default: 0)
            ))
        },
        FunctionSignature("IPMT", 4, 6) { call in
            .number(try interestPayment(
                rate: try call.number(0), period: try call.number(1), nper: try call.number(2),
                pv: try call.number(3), fv: try call.number(4, default: 0),
                type: try call.number(5, default: 0)
            ))
        },
        FunctionSignature("PPMT", 4, 6) { call in
            let rate = try call.number(0)
            let period = try call.number(1)
            let nper = try call.number(2)
            let pv = try call.number(3)
            let fv = try call.number(4, default: 0)
            let type = try call.number(5, default: 0)
            let total = try payment(rate: rate, nper: nper, pv: pv, fv: fv, type: type)
            let interest = try interestPayment(
                rate: rate, period: period, nper: nper, pv: pv, fv: fv, type: type
            )
            return .number(total - interest)
        },
    ]

    // MARK: - Cash-flow series

    private static let flows: [FunctionSignature] = [
        FunctionSignature("NPV", 2, .max) { call in
            let rate = try call.number(0)
            guard rate != -1 else { throw FormulaFault.cell(.divideByZero) }
            var total = 0.0
            var period = 1.0
            for element in try call.allElements(from: 1) {
                if let error = element.value.errorValue { throw FormulaFault.cell(error) }
                // Excel discounts *every* position of a range, blanks included, so a blank in
                // the middle of a cash-flow column does not shift the later flows a year
                // earlier. Text and booleans in a range are skipped without consuming a period.
                guard let amount = try FinancialFunctions.flowValue(element) else { continue }
                total += amount / pow(1 + rate, period)
                period += 1
            }
            return ExcelNumber.checked(total).formulaValue
        },
        FunctionSignature("IRR", 1, 2) { call in
            var flows: [Double] = []
            for element in try call.elements(from: 0) {
                if let error = element.value.errorValue { throw FormulaFault.cell(error) }
                guard let amount = try FinancialFunctions.flowValue(element) else { continue }
                flows.append(amount)
            }
            guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
                throw FormulaFault.cell(.invalidNumber)
            }
            let guess = try call.number(1, default: 0.1)
            return .number(try FinancialFunctions.internalRate(flows, guess: guess))
        },
    ]

    /// One cash flow, or `nil` for something a series skips.
    ///
    /// A blank inside a *range* still occupies its period — the position matters — so it comes
    /// back as `0` rather than `nil`; text and booleans in a range are skipped entirely, and a
    /// value written directly into the argument list is coerced the way Excel coerces it.
    private static func flowValue(_ element: (value: ScalarValue, viaReference: Bool)) throws -> Double? {
        guard element.viaReference else {
            switch element.value {
            case .blank: return 0
            case let .number(value): return value
            case let .text(text):
                guard let parsed = Coercion.plainNumber(fromText: text) else {
                    throw FormulaFault.cell(.wrongType)
                }
                return parsed
            case let .boolean(flag): return flag ? 1 : 0
            case .error: return nil
            }
        }
        switch element.value {
        case let .number(value): return value
        case .blank: return 0
        default: return nil
        }
    }

    /// `IRR` by Newton's method, falling back to bisection.
    ///
    /// Newton alone diverges on perfectly ordinary cash flows — a series that changes sign
    /// twice has a flat region where the derivative is nearly zero and the step overshoots to
    /// somewhere with no root. The bracketed fallback is what makes the answer exist at all
    /// for those, and `#NUM!` is what Excel gives when neither converges.
    static func internalRate(_ flows: [Double], guess: Double) throws -> Double {
        func netPresentValue(_ rate: Double) -> Double {
            var total = 0.0
            for (period, amount) in flows.enumerated() {
                total += amount / pow(1 + rate, Double(period))
            }
            return total
        }

        var rate = guess.isFinite && guess > -1 ? guess : 0.1
        for _ in 0 ..< 64 {
            let value = netPresentValue(rate)
            if abs(value) < 1e-10 { return rate }
            var derivative = 0.0
            for (period, amount) in flows.enumerated() where period > 0 {
                derivative -= Double(period) * amount / pow(1 + rate, Double(period) + 1)
            }
            guard derivative != 0, derivative.isFinite else { break }
            let next = rate - value / derivative
            guard next.isFinite, next > -1 else { break }
            if abs(next - rate) < 1e-12 { return next }
            rate = next
        }

        var low = -0.9999999
        var high = 10.0
        var lowValue = netPresentValue(low)
        guard lowValue.isFinite else { throw FormulaFault.cell(.invalidNumber) }
        var highValue = netPresentValue(high)
        guard lowValue * highValue <= 0 else { throw FormulaFault.cell(.invalidNumber) }
        for _ in 0 ..< 200 {
            let middle = (low + high) / 2
            let value = netPresentValue(middle)
            if abs(value) < 1e-10 || high - low < 1e-12 { return middle }
            if value * lowValue <= 0 {
                high = middle
                highValue = value
            } else {
                low = middle
                lowValue = value
            }
        }
        _ = highValue
        throw FormulaFault.cell(.invalidNumber)
    }

    // MARK: - Depreciation

    private static let depreciation: [FunctionSignature] = [
        FunctionSignature("SLN", 3, 3) { call in
            let life = try call.number(2)
            guard life != 0 else { throw FormulaFault.cell(.divideByZero) }
            return .number((try call.number(0) - (try call.number(1))) / life)
        },
        FunctionSignature("SYD", 4, 4) { call in
            let cost = try call.number(0)
            let salvage = try call.number(1)
            let life = try call.number(2)
            let period = try call.number(3)
            guard life > 0, period > 0, period <= life else { throw FormulaFault.cell(.invalidNumber) }
            return .number((cost - salvage) * (life - period + 1) * 2 / (life * (life + 1)))
        },
    ]
}

extension ScalarValue {
    /// This scalar as a ``FormulaValue``, for the functions that build one via
    /// ``ExcelNumber/checked(_:)``.
    var formulaValue: FormulaValue { .scalar(self) }
}
