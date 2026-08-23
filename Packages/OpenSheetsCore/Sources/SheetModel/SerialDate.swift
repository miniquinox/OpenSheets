import Foundation

/// Which epoch a workbook counts days from.
///
/// Both are real and both appear in the wild: Windows Excel defaults to 1900, Mac Excel used
/// to default to 1904, and the flag lives in `workbookPr/@date1904`. Reading a 1904 file as if
/// it were 1900 shifts every date by four years and a day, silently.
public enum DateSystem: String, Sendable, Hashable, Codable, CaseIterable {
    /// Serial 1 is 1900-01-01. Carries the Lotus leap-year bug — see ``SerialDate``.
    case excel1900
    /// Serial 0 is 1904-01-01. No phantom day.
    case excel1904

    /// Days from this system's serial 0 to 1970-01-01, for converting to and from `Date`.
    ///
    /// For 1900 this is the value that applies to serials at or past 61; earlier ones need the
    /// phantom-day correction, which ``SerialDate`` handles.
    public var unixEpochSerial: Double {
        switch self {
        case .excel1900: 25_569
        case .excel1904: 24_107
        }
    }
}

/// A calendar date and clock time, decomposed.
///
/// Deliberately not Foundation's `DateComponents`: every field here is non-optional, and one
/// of them records something `DateComponents` cannot express.
public struct DateTimeComponents: Sendable, Hashable, Codable {
    /// Proleptic Gregorian, so years before 1583 are extrapolated rather than historical.
    public var year: Int
    /// 1–12.
    public var month: Int
    /// 1–31.
    public var day: Int
    /// 0–23.
    public var hour: Int
    /// 0–59.
    public var minute: Int
    /// 0–59.
    public var second: Int
    /// 0–999.
    public var millisecond: Int

    /// 1 = Sunday, matching Excel's `WEEKDAY(serial, 1)`.
    public var weekday: Int

    /// This is 1900-02-29, a day that never happened.
    ///
    /// Lotus 1-2-3 treated 1900 as a leap year; Excel copied the bug on purpose for
    /// compatibility and has never fixed it, so serial 60 in the 1900 system is a date with no
    /// real counterpart. Rendering it as `1900-02-29` is the honest answer — it is what Excel
    /// shows — but converting it to a `Foundation.Date` is not possible, and
    /// ``SerialDate/date(serial:system:timeZone:)`` returns `nil` rather than sliding it to
    /// March 1st.
    public var isPhantomLeapDay: Bool

    /// The serial was at or before this system's epoch, so the date is extrapolated backwards.
    /// Excel refuses to display these; we compute them, and callers can decide.
    public var isBeforeEpoch: Bool

    public init(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, millisecond: Int = 0,
        weekday: Int = 1, isPhantomLeapDay: Bool = false, isBeforeEpoch: Bool = false
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.millisecond = millisecond
        self.weekday = weekday
        self.isPhantomLeapDay = isPhantomLeapDay
        self.isBeforeEpoch = isBeforeEpoch
    }
}

/// Conversion between Excel serial numbers and calendar dates.
///
/// Excel has no date type. `45000` is a number; a cell shows it as `2023-03-15` only because
/// its number format says to. So this is the boundary where a number becomes a date, and it
/// gets its own module for two reasons.
///
/// First, the arithmetic is pure and deterministic — no `Calendar`, no time zone, no `Date()`
/// — which makes every edge case unit-testable. Second, four different targets need it (the
/// reader, the formula engine's date functions, the renderer, and the MCP surface), and four
/// independent implementations of the Lotus leap-year bug is four chances to get it wrong.
///
/// # The phantom day
///
/// In the 1900 system, serial 60 is `1900-02-29` — a date that does not exist. Serials 1…59
/// are therefore **one day ahead** of a naive day count, and serials 61 and up line up
/// correctly. Every real spreadsheet lives past serial 61, so the bug is invisible right up
/// until someone types a date in January 1900.
public enum SerialDate {
    /// Decomposes a serial number into a date and a time.
    ///
    /// The fractional part is the time of day: `0.5` is noon. Times are rounded to the nearest
    /// millisecond and carried into the next day when that rounds up past midnight, so
    /// `0.9999999` reads as the next day at `00:00:00.000` rather than `23:59:59.999`.
    public static func components(serial: Double, system: DateSystem) -> DateTimeComponents {
        var wholeDays = Int(serial.rounded(.down))
        var fraction = serial - Double(wholeDays)

        // Round to a millisecond first so the carry happens before decomposition.
        var totalMilliseconds = Int((fraction * 86_400_000).rounded())
        if totalMilliseconds >= 86_400_000 {
            totalMilliseconds -= 86_400_000
            wholeDays += 1
            fraction = 0
        }
        if totalMilliseconds < 0 {
            totalMilliseconds += 86_400_000
            wholeDays -= 1
        }

        let hour = totalMilliseconds / 3_600_000
        let minute = (totalMilliseconds / 60_000) % 60
        let second = (totalMilliseconds / 1000) % 60
        let millisecond = totalMilliseconds % 1000
        let weekday = excelWeekday(wholeDays: wholeDays, system: system)

        if system == .excel1900, wholeDays == 60 {
            return DateTimeComponents(
                year: 1900, month: 2, day: 29,
                hour: hour, minute: minute, second: second, millisecond: millisecond,
                weekday: weekday, isPhantomLeapDay: true, isBeforeEpoch: false
            )
        }

        let (year, month, day) = civilFromDays(unixDays(wholeDays: wholeDays, system: system))
        return DateTimeComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second, millisecond: millisecond,
            weekday: weekday,
            isPhantomLeapDay: false,
            isBeforeEpoch: wholeDays < (system == .excel1900 ? 1 : 0)
        )
    }

    /// Composes a serial number from calendar and clock fields.
    ///
    /// Returns `nil` for a month or day outside its range. `1900-02-29` in the 1900 system is
    /// **accepted** and gives serial 60 — it is a date Excel can hold, so refusing it would
    /// make a legal file unwritable.
    public static func serial(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, millisecond: Int = 0,
        system: DateSystem
    ) -> Double? {
        guard (1 ... 12).contains(month), day >= 1, day <= 31 else { return nil }
        guard (0 ... 23).contains(hour) || hour == 24,
              (0 ... 59).contains(minute), (0 ... 59).contains(second),
              (0 ... 999).contains(millisecond)
        else { return nil }

        let timeFraction = Double(hour * 3_600_000 + minute * 60_000 + second * 1000 + millisecond) / 86_400_000

        if system == .excel1900, year == 1900, month == 2, day == 29 {
            return 60 + timeFraction
        }
        guard day <= daysInMonth(year: year, month: month) else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        return Double(serialDays(unixDays: days, system: system)) + timeFraction
    }

    /// Composes a serial from decomposed components. See
    /// ``serial(year:month:day:hour:minute:second:millisecond:system:)``.
    public static func serial(from components: DateTimeComponents, system: DateSystem) -> Double? {
        serial(
            year: components.year, month: components.month, day: components.day,
            hour: components.hour, minute: components.minute,
            second: components.second, millisecond: components.millisecond,
            system: system
        )
    }

    /// A serial as a `Foundation.Date`, interpreting the fields in `timeZone`.
    ///
    /// Returns `nil` for the phantom leap day, which has no instant to point at. Defaults to
    /// GMT because a spreadsheet's dates are wall-clock values with no zone of their own —
    /// interpreting them in the local zone makes the same file mean different things on
    /// different machines.
    public static func date(serial: Double, system: DateSystem, timeZone: TimeZone = .gmt) -> Date? {
        let parts = components(serial: serial, system: system)
        guard !parts.isPhantomLeapDay else { return nil }
        let days = daysFromCivil(year: parts.year, month: parts.month, day: parts.day)
        let seconds = Double(days) * 86_400
            + Double(parts.hour * 3600 + parts.minute * 60 + parts.second)
            + Double(parts.millisecond) / 1000
            - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(days) * 86_400)))
        return Date(timeIntervalSince1970: seconds)
    }

    /// A `Foundation.Date` as a serial, reading its fields in `timeZone`.
    public static func serial(from date: Date, system: DateSystem, timeZone: TimeZone = .gmt) -> Double {
        let shifted = date.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: date))
        let days = Int((shifted / 86_400).rounded(.down))
        let secondsIntoDay = shifted - Double(days) * 86_400
        return Double(serialDays(unixDays: days, system: system)) + secondsIntoDay / 86_400
    }

    /// Whether `year` is a leap year in the proleptic Gregorian calendar.
    ///
    /// 1900 is **not** a leap year here, whatever serial 60 says. The phantom day is a quirk of
    /// the serial numbering, not a claim about the calendar, and mixing the two is how date
    /// arithmetic goes wrong.
    public static func isLeapYear(_ year: Int) -> Bool {
        (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) || year.isMultiple(of: 400)
    }

    /// Days in a month, 1-based month.
    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: 31
        case 4, 6, 9, 11: 30
        case 2: isLeapYear(year) ? 29 : 28
        default: 0
        }
    }

    // MARK: - Serial ↔ days-since-1970

    /// Converts a whole-day serial to days since 1970-01-01, correcting for the phantom day.
    private static func unixDays(wholeDays: Int, system: DateSystem) -> Int {
        switch system {
        case .excel1904:
            wholeDays - 24_107
        case .excel1900:
            // Serials 1…59 predate the phantom day, so they are one *less* far from the epoch
            // than the naive arithmetic says.
            wholeDays < 60 ? wholeDays - 25_568 : wholeDays - 25_569
        }
    }

    /// The inverse of ``unixDays(wholeDays:system:)``.
    private static func serialDays(unixDays: Int, system: DateSystem) -> Int {
        switch system {
        case .excel1904:
            unixDays + 24_107
        case .excel1900:
            unixDays <= -25_509 ? unixDays + 25_568 : unixDays + 25_569
        }
    }

    /// Excel's own weekday, computed from the serial rather than from the calendar.
    ///
    /// This reproduces Excel exactly, including its disagreement with reality for serials 1…59
    /// — `WEEKDAY(1)` is 1 (Sunday) even though 1900-01-01 was a Monday. Deriving the weekday
    /// from the corrected calendar date instead would be *more correct* and would disagree
    /// with every formula in every existing spreadsheet, so it does not.
    private static func excelWeekday(wholeDays: Int, system: DateSystem) -> Int {
        let offset = system == .excel1900 ? -1 : 5
        return floorModulo(wholeDays + offset, 7) + 1
    }

    private static func floorModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder < 0 ? remainder + modulus : remainder
    }

    // MARK: - Proleptic Gregorian arithmetic

    /// Days from 1970-01-01 to a civil date. Howard Hinnant's `days_from_civil`, which is
    /// branch-free, exact for any year, and does not go anywhere near `Calendar`.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The inverse: `civil_from_days`.
    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (year + (month <= 2 ? 1 : 0), month, day)
    }
}
