import Foundation
import SheetModel

/// Aggregates and descriptive statistics.
///
/// The `.P`/`.S` split matters and is easy to get backwards: `STDEV.P` divides by `n`
/// (the whole population), `STDEV.S` by `n-1` (a sample). Excel's legacy `STDEV` is the
/// *sample* one and `STDEVP` the population one, so the old and new spellings pair up
/// crosswise. Both spellings are implemented and both are in the table tests.
enum StatisticsFunctions {
    static var signatures: [FunctionSignature] { counting + spread + ordering + products }

    // MARK: - Counting and extremes

    private static let counting: [FunctionSignature] = [
        FunctionSignature("AVERAGE", 1, .max) { call in
            let values = try call.requireNonEmpty(try call.numbers(from: 0))
            return .number(ExcelNumber.sum(values) / Double(values.count))
        },
        FunctionSignature("AVERAGEA", 1, .max) { call in
            let values = try StatisticsFunctions.permissiveNumbers(call)
            guard !values.isEmpty else { throw FormulaFault.cell(.divideByZero) }
            return .number(ExcelNumber.sum(values) / Double(values.count))
        },
        FunctionSignature("COUNT", 1, .max) { call in
            var count = 0
            for element in try call.allElements(from: 0) {
                if element.viaReference {
                    if case .number = element.value { count += 1 }
                } else {
                    switch element.value {
                    case .number, .boolean: count += 1
                    case let .text(text):
                        if Coercion.number(fromText: text, dateSystem: call.scope.options.dateSystem) != nil {
                            count += 1
                        }
                    default: break
                    }
                }
            }
            return .number(Double(count))
        },
        FunctionSignature("COUNTA", 1, .max, propagatesErrors: false) { call in
            var count = 0
            for element in try call.allElements(from: 0) {
                if case .blank = element.value {
                    // A directly written empty argument still counts: `COUNTA(1,)` is 2.
                    if !element.viaReference { count += 1 }
                } else {
                    count += 1
                }
            }
            return .number(Double(count))
        },
        FunctionSignature("COUNTBLANK", 1, 1, propagatesErrors: false) { call in
            let part = try call.range(0)
            let total = part.range.clampedToSheet.cellCount
            var populated = 0
            call.scope.forEachPopulated(in: part) { _, value in
                if case .blank = value { return }
                if case let .text(text) = value, text.isEmpty { return }
                populated += 1
            }
            return .number(Double(total - populated))
        },
        FunctionSignature("MIN", 1, .max) { call in
            .number(try call.numbers(from: 0).min() ?? 0)
        },
        FunctionSignature("MAX", 1, .max) { call in
            .number(try call.numbers(from: 0).max() ?? 0)
        },
        FunctionSignature("MINA", 1, .max) { call in
            .number(try StatisticsFunctions.permissiveNumbers(call).min() ?? 0)
        },
        FunctionSignature("MAXA", 1, .max) { call in
            .number(try StatisticsFunctions.permissiveNumbers(call).max() ?? 0)
        },
    ]

    // MARK: - Spread

    private static let spread: [FunctionSignature] = [
        FunctionSignature("MEDIAN", 1, .max) { call in
            let values = try call.requireNonEmpty(try call.numbers(from: 0)).sorted()
            let middle = values.count / 2
            return .number(values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2)
        },
        FunctionSignature("VAR", 1, .max) { call in try StatisticsFunctions.variance(call, population: false) },
        FunctionSignature("VAR.S", 1, .max, prefixed: true) { call in
            try StatisticsFunctions.variance(call, population: false)
        },
        FunctionSignature("VARP", 1, .max) { call in try StatisticsFunctions.variance(call, population: true) },
        FunctionSignature("VAR.P", 1, .max, prefixed: true) { call in
            try StatisticsFunctions.variance(call, population: true)
        },
        FunctionSignature("STDEV", 1, .max) { call in try StatisticsFunctions.deviation(call, population: false) },
        FunctionSignature("STDEV.S", 1, .max, prefixed: true) { call in
            try StatisticsFunctions.deviation(call, population: false)
        },
        FunctionSignature("STDEVP", 1, .max) { call in try StatisticsFunctions.deviation(call, population: true) },
        FunctionSignature("STDEV.P", 1, .max, prefixed: true) { call in
            try StatisticsFunctions.deviation(call, population: true)
        },
        FunctionSignature("CORREL", 2, 2) { call in
            let x = try StatisticsFunctions.pairedValues(call, 0)
            let y = try StatisticsFunctions.pairedValues(call, 1)
            guard x.count == y.count, x.count >= 2 else { throw FormulaFault.cell(.notAvailable) }
            let meanX = ExcelNumber.sum(x) / Double(x.count)
            let meanY = ExcelNumber.sum(y) / Double(y.count)
            var covariance = 0.0
            var varianceX = 0.0
            var varianceY = 0.0
            for index in 0 ..< x.count {
                let dx = x[index] - meanX
                let dy = y[index] - meanY
                covariance += dx * dy
                varianceX += dx * dx
                varianceY += dy * dy
            }
            guard varianceX > 0, varianceY > 0 else { throw FormulaFault.cell(.divideByZero) }
            return .number(covariance / (varianceX * varianceY).squareRoot())
        },
    ]

    // MARK: - Ordering

    private static let ordering: [FunctionSignature] = [
        FunctionSignature("PERCENTILE", 2, 2) { call in
            try .number(StatisticsFunctions.percentile(try call.numbers(atArgument: 0), try call.number(1)))
        },
        FunctionSignature("PERCENTILE.INC", 2, 2, prefixed: true) { call in
            try .number(StatisticsFunctions.percentile(try call.numbers(atArgument: 0), try call.number(1)))
        },
        FunctionSignature("QUARTILE", 2, 2) { call in
            let quarter = try call.integer(1)
            guard quarter >= 0, quarter <= 4 else { throw FormulaFault.cell(.invalidNumber) }
            return try .number(StatisticsFunctions.percentile(try call.numbers(atArgument: 0), Double(quarter) / 4))
        },
        FunctionSignature("QUARTILE.INC", 2, 2, prefixed: true) { call in
            let quarter = try call.integer(1)
            guard quarter >= 0, quarter <= 4 else { throw FormulaFault.cell(.invalidNumber) }
            return try .number(StatisticsFunctions.percentile(try call.numbers(atArgument: 0), Double(quarter) / 4))
        },
        FunctionSignature("LARGE", 2, 2) { call in
            let values = try call.numbers(atArgument: 0).sorted(by: >)
            let index = try call.integer(1)
            guard index >= 1, index <= values.count else { throw FormulaFault.cell(.invalidNumber) }
            return .number(values[index - 1])
        },
        FunctionSignature("SMALL", 2, 2) { call in
            let values = try call.numbers(atArgument: 0).sorted()
            let index = try call.integer(1)
            guard index >= 1, index <= values.count else { throw FormulaFault.cell(.invalidNumber) }
            return .number(values[index - 1])
        },
        FunctionSignature("RANK", 2, 3) { call in try StatisticsFunctions.rank(call) },
        FunctionSignature("RANK.EQ", 2, 3, prefixed: true) { call in try StatisticsFunctions.rank(call) },
    ]

    // MARK: - Products and subtotals

    private static let products: [FunctionSignature] = [
        FunctionSignature("SUMPRODUCT", 1, .max) { call in
            var tables: [ValueArray] = []
            for index in 0 ..< call.count { tables.append(try call.table(index)) }
            guard let first = tables.first else { throw FormulaFault.cell(.wrongType) }
            guard tables.allSatisfy({ $0.rowCount == first.rowCount && $0.columnCount == first.columnCount }) else {
                throw FormulaFault.cell(.wrongType)
            }
            var total = 0.0
            for position in 0 ..< first.count {
                var product = 1.0
                for table in tables {
                    if let error = table.values[position].errorValue { throw FormulaFault.cell(error) }
                    // Anything that is not a number contributes zero, which is what makes
                    // `SUMPRODUCT((A:A="x")*1,B:B)` the idiom it is.
                    guard case let .number(value) = table.values[position] else {
                        product = 0
                        break
                    }
                    product *= value
                }
                total = ExcelNumber.add(total, product)
            }
            return .number(total)
        },
        FunctionSignature("SUBTOTAL", 2, .max) { call in
            let code = try call.integer(0)
            let ignoresHidden = code > 100
            let operation = ignoresHidden ? code - 100 : code
            guard (1 ... 11).contains(operation) else { throw FormulaFault.cell(.invalidNumber) }
            let collected = try StatisticsFunctions.subtotalValues(call, ignoresHidden: ignoresHidden)
            return try StatisticsFunctions.applySubtotal(operation, to: collected)
        },
    ]

    // MARK: - Helpers

    private static func permissiveNumbers(_ call: FunctionCallSite) throws -> [Double] {
        var result: [Double] = []
        for element in try call.allElements(from: 0) {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            switch element.value {
            case let .number(value): result.append(value)
            case let .boolean(flag): result.append(flag ? 1 : 0)
            case .text: result.append(0)
            case .blank: if !element.viaReference { result.append(0) }
            case .error: break
            }
        }
        return result
    }

    private static func variance(_ call: FunctionCallSite, population: Bool) throws -> FormulaValue {
        .number(try dispersion(try call.numbers(from: 0), population: population))
    }

    private static func deviation(_ call: FunctionCallSite, population: Bool) throws -> FormulaValue {
        .number(try dispersion(try call.numbers(from: 0), population: population).squareRoot())
    }

    private static func dispersion(_ values: [Double], population: Bool) throws -> Double {
        let divisor = population ? values.count : values.count - 1
        guard divisor > 0 else { throw FormulaFault.cell(.divideByZero) }
        let mean = ExcelNumber.sum(values) / Double(values.count)
        let total = ExcelNumber.sum(values.map { ($0 - mean) * ($0 - mean) })
        return total / Double(divisor)
    }

    private static func pairedValues(_ call: FunctionCallSite, _ index: Int) throws -> [Double] {
        var result: [Double] = []
        for element in try call.elements(from: index) {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            if case let .number(value) = element.value { result.append(value) }
        }
        return result
    }

    /// The inclusive percentile — Excel's `PERCENTILE`, `PERCENTILE.INC` and `QUARTILE`.
    static func percentile(_ values: [Double], _ fraction: Double) throws -> Double {
        guard !values.isEmpty else { throw FormulaFault.cell(.invalidNumber) }
        guard fraction >= 0, fraction <= 1 else { throw FormulaFault.cell(.invalidNumber) }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let remainder = position - Double(lower)
        guard lower + 1 < sorted.count else { return sorted[lower] }
        return sorted[lower] + remainder * (sorted[lower + 1] - sorted[lower])
    }

    private static func rank(_ call: FunctionCallSite) throws -> FormulaValue {
        let target = try call.number(0)
        var values: [Double] = []
        for element in try call.elements(from: 1) {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            if case let .number(value) = element.value { values.append(value) }
        }
        guard values.contains(target) else { throw FormulaFault.cell(.notAvailable) }
        let ascending = try call.integer(2, default: 0) != 0
        let better = values.filter { ascending ? $0 < target : $0 > target }.count
        return .number(Double(better + 1))
    }

    private struct SubtotalInput {
        var numbers: [Double] = []
        var nonEmpty = 0
    }

    private static func subtotalValues(
        _ call: FunctionCallSite, ignoresHidden: Bool
    ) throws -> SubtotalInput {
        var result = SubtotalInput()
        for index in 1 ..< call.count {
            guard index < call.arguments.count else { continue }
            guard case let .reference(reference) = call.arguments[index] else {
                for element in try call.elements(from: index) {
                    if let error = element.value.errorValue { throw FormulaFault.cell(error) }
                    if case .blank = element.value { continue }
                    result.nonEmpty += 1
                    if case let .number(number) = element.value { result.numbers.append(number) }
                }
                continue
            }
            for part in reference.parts {
                var fault: CellError?
                call.scope.forEachPopulated(in: part) { cell, value in
                    if let error = value.errorValue {
                        fault = fault ?? error
                        return
                    }
                    if ignoresHidden, call.scope.isRowHidden(cell) { return }
                    if case .blank = value { return }
                    result.nonEmpty += 1
                    if case let .number(number) = value { result.numbers.append(number) }
                }
                if let fault { throw FormulaFault.cell(fault) }
            }
        }
        return result
    }

    private static func applySubtotal(_ operation: Int, to input: SubtotalInput) throws -> FormulaValue {
        let values = input.numbers
        switch operation {
        case 1:
            guard !values.isEmpty else { throw FormulaFault.cell(.divideByZero) }
            return .number(ExcelNumber.sum(values) / Double(values.count))
        case 2: return .number(Double(values.count))
        case 3: return .number(Double(input.nonEmpty))
        case 4: return .number(values.max() ?? 0)
        case 5: return .number(values.min() ?? 0)
        case 6: return .number(values.reduce(1, *))
        case 7: return .number(try dispersion(values, population: false).squareRoot())
        case 8: return .number(try dispersion(values, population: true).squareRoot())
        case 9: return .number(ExcelNumber.sum(values))
        case 10: return .number(try dispersion(values, population: false))
        default: return .number(try dispersion(values, population: true))
        }
    }
}
