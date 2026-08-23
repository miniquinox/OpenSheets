import Foundation
import SheetModel

/// Dates, which in a spreadsheet are numbers.
///
/// Every conversion here goes through ``SerialDate`` with the **workbook's** epoch, taken from
/// ``EvaluationOptions/dateSystem``. Nothing assumes 1900: a Mac-authored 1904 workbook whose
/// dates were read as 1900 would be wrong by four years and a day in every cell, and the bug
/// would look like a data-entry mistake rather than an engine one.
enum DateFunctions {
    static var signatures: [FunctionSignature] { construction + extraction + arithmetic }

    // MARK: - Construction

    private static let construction: [FunctionSignature] = [
        FunctionSignature("TODAY", 0, 0, volatile: true) { call in
            .number(call.scope.options.now.rounded(.down))
        },
        FunctionSignature("NOW", 0, 0, volatile: true) { call in .number(call.scope.options.now) },
        FunctionSignature("DATE", 3, 3) { call in
            let serial = try DateFunctions.compose(
                year: try call.integer(0), month: try call.integer(1), day: try call.integer(2),
                system: call.scope.options.dateSystem
            )
            guard serial >= 0 else { throw FormulaFault.cell(.invalidNumber) }
            return .number(serial)
        },
        FunctionSignature("TIME", 3, 3) { call in
            let hours = try call.integer(0)
            let minutes = try call.integer(1)
            let seconds = try call.integer(2)
            guard hours >= 0, minutes >= 0, seconds >= 0 else { throw FormulaFault.cell(.invalidNumber) }
            let total = Double(hours * 3600 + minutes * 60 + seconds)
            // Excel wraps past midnight rather than overflowing into a day count.
            return .number(total.truncatingRemainder(dividingBy: 86_400) / 86_400)
        },
        FunctionSignature("DATEVALUE", 1, 1) { call in
            guard let serial = Coercion.dateSerial(
                fromText: try call.text(0), dateSystem: call.scope.options.dateSystem
            ) else { throw FormulaFault.cell(.wrongType) }
            return .number(serial.rounded(.down))
        },
        FunctionSignature("TIMEVALUE", 1, 1) { call in
            guard let serial = Coercion.dateSerial(
                fromText: try call.text(0), dateSystem: call.scope.options.dateSystem
            ) else { throw FormulaFault.cell(.wrongType) }
            return .number(serial - serial.rounded(.down))
        },
    ]

    // MARK: - Extraction

    private static let extraction: [FunctionSignature] = [
        FunctionSignature("YEAR", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).year))
        },
        FunctionSignature("MONTH", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).month))
        },
        FunctionSignature("DAY", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).day))
        },
        FunctionSignature("HOUR", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).hour))
        },
        FunctionSignature("MINUTE", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).minute))
        },
        FunctionSignature("SECOND", 1, 1) { call in
            .number(Double(try DateFunctions.parts(call, 0).second))
        },
        FunctionSignature("WEEKDAY", 1, 2) { call in
            let parts = try DateFunctions.parts(call, 0)
            return .number(Double(DateFunctions.weekday(parts.weekday, type: try call.integer(1, default: 1))))
        },
        FunctionSignature("WEEKNUM", 1, 2) { call in
            let serial = try DateFunctions.serial(call, 0)
            return .number(Double(try DateFunctions.weekNumber(
                serial, type: try call.integer(1, default: 1), system: call.scope.options.dateSystem
            )))
        },
    ]

    // MARK: - Arithmetic

    private static let arithmetic: [FunctionSignature] = [
        FunctionSignature("EDATE", 2, 2) { call in
            .number(try DateFunctions.shiftMonths(
                try DateFunctions.serial(call, 0), by: try call.integer(1),
                toEndOfMonth: false, system: call.scope.options.dateSystem
            ))
        },
        FunctionSignature("EOMONTH", 2, 2) { call in
            .number(try DateFunctions.shiftMonths(
                try DateFunctions.serial(call, 0), by: try call.integer(1),
                toEndOfMonth: true, system: call.scope.options.dateSystem
            ))
        },
        FunctionSignature("DAYS", 2, 2) { call in
            .number((try DateFunctions.serial(call, 0)).rounded(.down) - (try DateFunctions.serial(call, 1)).rounded(.down))
        },
        FunctionSignature("DATEDIF", 3, 3) { call in
            let start = try DateFunctions.serial(call, 0).rounded(.down)
            let end = try DateFunctions.serial(call, 1).rounded(.down)
            guard end >= start else { throw FormulaFault.cell(.invalidNumber) }
            return .number(Double(try DateFunctions.difference(
                start, end, unit: try call.text(2).uppercased(), system: call.scope.options.dateSystem
            )))
        },
        FunctionSignature("NETWORKDAYS", 2, 3) { call in
            let start = try DateFunctions.serial(call, 0).rounded(.down)
            let end = try DateFunctions.serial(call, 1).rounded(.down)
            let holidays = try DateFunctions.holidays(call, 2)
            let step = start <= end ? 1.0 : -1.0
            var count = 0
            var cursor = start
            while step > 0 ? cursor <= end : cursor >= end {
                if DateFunctions.isWorkday(cursor, holidays: holidays, system: call.scope.options.dateSystem) {
                    count += 1
                }
                cursor += step
            }
            return .number(Double(step > 0 ? count : -count))
        },
        FunctionSignature("WORKDAY", 2, 3) { call in
            var cursor = try DateFunctions.serial(call, 0).rounded(.down)
            var remaining = try call.integer(1)
            let holidays = try DateFunctions.holidays(call, 2)
            let step = remaining >= 0 ? 1.0 : -1.0
            remaining = abs(remaining)
            while remaining > 0 {
                cursor += step
                if DateFunctions.isWorkday(cursor, holidays: holidays, system: call.scope.options.dateSystem) {
                    remaining -= 1
                }
            }
            return .number(cursor)
        },
    ]

    // MARK: - Helpers

    private static func serial(_ call: FunctionCallSite, _ index: Int) throws -> Double {
        let value = try call.number(index)
        guard value >= 0, value < 2_958_466 else { throw FormulaFault.cell(.invalidNumber) }
        return value
    }

    private static func parts(_ call: FunctionCallSite, _ index: Int) throws -> DateTimeComponents {
        SerialDate.components(serial: try serial(call, index), system: call.scope.options.dateSystem)
    }

    /// `DATE(2024,13,1)` is January 2025 — Excel normalises out-of-range months and days
    /// rather than rejecting them, and a two-digit year below 1900 is offset from 1900.
    static func compose(year: Int, month: Int, day: Int, system: DateSystem) throws -> Double {
        var resolvedYear = year
        if resolvedYear >= 0, resolvedYear < 1900 { resolvedYear += 1900 }
        guard resolvedYear >= 0, resolvedYear <= 9999 else { throw FormulaFault.cell(.invalidNumber) }

        let monthOffset = month - 1
        resolvedYear += Int((Double(monthOffset) / 12).rounded(.down))
        var normalisedMonth = monthOffset % 12
        if normalisedMonth < 0 { normalisedMonth += 12 }

        guard let base = SerialDate.serial(year: resolvedYear, month: normalisedMonth + 1, day: 1, system: system)
        else { throw FormulaFault.cell(.invalidNumber) }
        return base + Double(day - 1)
    }

    static func weekday(_ excelWeekday: Int, type: Int) -> Int {
        // `excelWeekday` is 1 = Sunday, which is type 1 already.
        switch type {
        case 1, 17: return excelWeekday
        case 2, 11: return (excelWeekday + 5) % 7 + 1
        case 3: return (excelWeekday + 5) % 7
        case 12 ... 16: return (excelWeekday + 7 - (type - 10)) % 7 + 1
        default: return excelWeekday
        }
    }

    static func weekNumber(_ serial: Double, type: Int, system: DateSystem) throws -> Int {
        let parts = SerialDate.components(serial: serial, system: system)
        guard let january = SerialDate.serial(year: parts.year, month: 1, day: 1, system: system) else {
            throw FormulaFault.cell(.invalidNumber)
        }
        let startsMonday = type == 2 || type == 11 || (type >= 12 && type <= 17)
        let januaryParts = SerialDate.components(serial: january, system: system)
        let offset = startsMonday ? (januaryParts.weekday + 5) % 7 : januaryParts.weekday - 1
        let elapsed = Int(serial.rounded(.down) - january)
        return (elapsed + offset) / 7 + 1
    }

    static func shiftMonths(_ serial: Double, by months: Int, toEndOfMonth: Bool, system: DateSystem) throws -> Double {
        let parts = SerialDate.components(serial: serial, system: system)
        var year = parts.year
        var month = parts.month - 1 + months
        year += Int((Double(month) / 12).rounded(.down))
        month %= 12
        if month < 0 { month += 12 }
        let lastDay = SerialDate.daysInMonth(year: year, month: month + 1)
        let day = toEndOfMonth ? lastDay : min(parts.day, lastDay)
        guard let result = SerialDate.serial(year: year, month: month + 1, day: day, system: system) else {
            throw FormulaFault.cell(.invalidNumber)
        }
        return result
    }

    static func difference(_ start: Double, _ end: Double, unit: String, system: DateSystem) throws -> Int {
        let from = SerialDate.components(serial: start, system: system)
        let to = SerialDate.components(serial: end, system: system)
        var wholeMonths = (to.year - from.year) * 12 + (to.month - from.month)
        if to.day < from.day { wholeMonths -= 1 }

        switch unit {
        case "D": return Int(end - start)
        case "M": return wholeMonths
        case "Y": return wholeMonths / 12
        case "MD":
            let anchor = try shiftMonths(start, by: wholeMonths, toEndOfMonth: false, system: system)
            return Int(end - anchor)
        case "YM": return wholeMonths % 12
        case "YD":
            let anchor = try shiftMonths(start, by: (wholeMonths / 12) * 12, toEndOfMonth: false, system: system)
            return Int(end - anchor)
        default: throw FormulaFault.cell(.invalidNumber)
        }
    }

    private static func holidays(_ call: FunctionCallSite, _ index: Int) throws -> Set<Double> {
        guard index < call.count else { return [] }
        var result: Set<Double> = []
        for element in try call.elements(from: index) {
            if let error = element.value.errorValue { throw FormulaFault.cell(error) }
            if case let .number(value) = element.value { result.insert(value.rounded(.down)) }
        }
        return result
    }

    private static func isWorkday(_ serial: Double, holidays: Set<Double>, system: DateSystem) -> Bool {
        let parts = SerialDate.components(serial: serial, system: system)
        // 1 is Sunday, 7 is Saturday.
        guard parts.weekday != 1, parts.weekday != 7 else { return false }
        return !holidays.contains(serial)
    }
}
