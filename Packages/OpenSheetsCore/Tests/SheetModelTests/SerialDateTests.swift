import Foundation
@testable import SheetModel
import Testing

@Suite("SerialDate")
struct SerialDateTests {
    @Test("the 1900 system's anchor dates", arguments: [
        (1.0, 1900, 1, 1),
        (2.0, 1900, 1, 2),
        (31.0, 1900, 1, 31),
        (32.0, 1900, 2, 1),
        (59.0, 1900, 2, 28),
        (61.0, 1900, 3, 1),
        (366.0, 1900, 12, 31),
        (367.0, 1901, 1, 1),
        (25_569.0, 1970, 1, 1),
        (45_000.0, 2023, 3, 15),
        (2_958_465.0, 9999, 12, 31),
    ])
    func nineteenHundredAnchors(_ serial: Double, _ year: Int, _ month: Int, _ day: Int) {
        let parts = SerialDate.components(serial: serial, system: .excel1900)
        #expect(
            parts.year == year && parts.month == month && parts.day == day,
            "serial \(serial) gave \(parts.year)-\(parts.month)-\(parts.day)"
        )
        #expect(SerialDate.serial(year: year, month: month, day: day, system: .excel1900) == serial)
    }

    @Test("serial 60 is 1900-02-29, a day that never happened")
    func phantomLeapDay() {
        let parts = SerialDate.components(serial: 60, system: .excel1900)
        #expect(parts.year == 1900)
        #expect(parts.month == 2)
        #expect(parts.day == 29)
        #expect(parts.isPhantomLeapDay)

        // It round-trips, because it is a value a real file can hold.
        #expect(SerialDate.serial(year: 1900, month: 2, day: 29, system: .excel1900) == 60)

        // But it has no instant, so it does not become a Date.
        #expect(SerialDate.date(serial: 60, system: .excel1900) == nil)

        // Its neighbours are unaffected.
        #expect(!SerialDate.components(serial: 59, system: .excel1900).isPhantomLeapDay)
        #expect(!SerialDate.components(serial: 61, system: .excel1900).isPhantomLeapDay)
    }

    @Test("1900 is not a leap year, whatever serial 60 claims")
    func leapYearRules() {
        #expect(!SerialDate.isLeapYear(1900))
        #expect(SerialDate.isLeapYear(2000))
        #expect(SerialDate.isLeapYear(2024))
        #expect(!SerialDate.isLeapYear(2023))
        #expect(!SerialDate.isLeapYear(2100))
        #expect(SerialDate.daysInMonth(year: 1900, month: 2) == 28)
        #expect(SerialDate.daysInMonth(year: 2024, month: 2) == 29)
    }

    @Test("the 1904 system's anchor dates", arguments: [
        (0.0, 1904, 1, 1),
        (1.0, 1904, 1, 2),
        (24_107.0, 1970, 1, 1),
        (43_538.0, 2023, 3, 15),
    ])
    func nineteenOhFourAnchors(_ serial: Double, _ year: Int, _ month: Int, _ day: Int) {
        let parts = SerialDate.components(serial: serial, system: .excel1904)
        #expect(parts.year == year && parts.month == month && parts.day == day)
        #expect(SerialDate.serial(year: year, month: month, day: day, system: .excel1904) == serial)
    }

    @Test("the two epochs describe the same wall-clock day from different serials")
    func epochsAgreeOnDates() {
        // 2023-03-15 is serial 45000 in the 1900 system and 43538 in the 1904 system.
        let fromNineteenHundred = SerialDate.components(serial: 45_000, system: .excel1900)
        let fromNineteenOhFour = SerialDate.components(serial: 43_538, system: .excel1904)
        #expect(fromNineteenHundred.year == fromNineteenOhFour.year)
        #expect(fromNineteenHundred.month == fromNineteenOhFour.month)
        #expect(fromNineteenHundred.day == fromNineteenOhFour.day)
        // The offset between the two systems is exactly 1462 days.
        #expect(45_000 - 43_538 == 1462)
    }

    @Test("the fractional part is the time of day")
    func timeOfDay() {
        let noon = SerialDate.components(serial: 45_000.5, system: .excel1900)
        #expect(noon.hour == 12 && noon.minute == 0 && noon.second == 0)

        let quarterPast = SerialDate.components(serial: 45_000.0 + 9.0 / 24 + 15.0 / 1440, system: .excel1900)
        #expect(quarterPast.hour == 9 && quarterPast.minute == 15)

        let lastSecond = SerialDate.components(serial: 45_000.0 + 86_399.0 / 86_400, system: .excel1900)
        #expect(lastSecond.hour == 23 && lastSecond.minute == 59 && lastSecond.second == 59)
    }

    @Test("a time that rounds up past midnight carries into the next day")
    func midnightCarry() {
        // The largest Double below 45001 — a hair under midnight, which rounds up to it.
        let almost = SerialDate.components(serial: Double(45_001).nextDown, system: .excel1900)
        #expect(almost.day == 16, "should have rolled into the 16th rather than reading 23:59:59.999")
        #expect(almost.hour == 0 && almost.minute == 0 && almost.second == 0)

        // A hair under *that* stays on the 15th, so the carry is not just always firing.
        let stillYesterday = SerialDate.components(serial: 45_000.9999999, system: .excel1900)
        #expect(stillYesterday.day == 15)
        #expect(stillYesterday.hour == 23 && stillYesterday.minute == 59)
    }

    @Test("times round-trip to the millisecond")
    func timeRoundTrip() {
        for (hour, minute, second) in [(0, 0, 0), (9, 30, 0), (12, 0, 0), (23, 59, 59), (6, 15, 45)] {
            let serial = SerialDate.serial(
                year: 2023, month: 3, day: 15, hour: hour, minute: minute, second: second, system: .excel1900
            )
            let parts = SerialDate.components(serial: serial ?? 0, system: .excel1900)
            #expect(
                parts.hour == hour && parts.minute == minute && parts.second == second,
                "\(hour):\(minute):\(second) came back as \(parts.hour):\(parts.minute):\(parts.second)"
            )
        }
    }

    @Test("weekdays match Excel, including where Excel disagrees with history")
    func weekdays() {
        // 1900-03-01 really was a Thursday, and Excel agrees past the phantom day.
        #expect(SerialDate.components(serial: 61, system: .excel1900).weekday == 5)
        // Excel calls serial 1 a Sunday even though 1900-01-01 was a Monday. Matching Excel
        // matters more than matching the calendar: every existing WEEKDAY formula assumes it.
        #expect(SerialDate.components(serial: 1, system: .excel1900).weekday == 1)
        // 1970-01-01 was a Thursday.
        #expect(SerialDate.components(serial: 25_569, system: .excel1900).weekday == 5)
        // 2023-03-15 was a Wednesday.
        #expect(SerialDate.components(serial: 45_000, system: .excel1900).weekday == 4)
        // 1904-01-01 was a Friday.
        #expect(SerialDate.components(serial: 0, system: .excel1904).weekday == 6)
    }

    @Test("serials at or before the epoch are flagged rather than refused")
    func beforeTheEpoch() {
        let zero = SerialDate.components(serial: 0, system: .excel1900)
        #expect(zero.isBeforeEpoch)
        #expect(zero.year == 1899 && zero.month == 12 && zero.day == 31)

        let negative = SerialDate.components(serial: -365, system: .excel1900)
        #expect(negative.isBeforeEpoch)
        #expect(negative.year == 1898)

        #expect(!SerialDate.components(serial: 1, system: .excel1900).isBeforeEpoch)
    }

    @Test("nonsense calendar fields produce no serial")
    func rejectsImpossibleDates() {
        #expect(SerialDate.serial(year: 2023, month: 13, day: 1, system: .excel1900) == nil)
        #expect(SerialDate.serial(year: 2023, month: 0, day: 1, system: .excel1900) == nil)
        #expect(SerialDate.serial(year: 2023, month: 2, day: 30, system: .excel1900) == nil)
        #expect(SerialDate.serial(year: 2023, month: 2, day: 29, system: .excel1900) == nil)
        #expect(SerialDate.serial(year: 2024, month: 2, day: 29, system: .excel1900) != nil)
        #expect(SerialDate.serial(year: 2023, month: 1, day: 1, minute: 61, system: .excel1900) == nil)
    }

    @Test("Foundation Date conversion round-trips in GMT")
    func foundationBridging() throws {
        let serial = 45_000.5
        let date = try #require(SerialDate.date(serial: serial, system: .excel1900))
        let back = SerialDate.serial(from: date, system: .excel1900)
        #expect(abs(back - serial) < 1e-6)

        let epoch = Date(timeIntervalSince1970: 0)
        #expect(SerialDate.serial(from: epoch, system: .excel1900) == 25_569)
        #expect(SerialDate.serial(from: epoch, system: .excel1904) == 24_107)
    }

    @Test("a decade of days round-trips through both systems")
    func exhaustiveRoundTrip() {
        for system in DateSystem.allCases {
            // Start past the phantom day so the sweep is unambiguous; the phantom has its own test.
            let start = system == .excel1900 ? 40_000 : 38_500
            for serial in stride(from: start, to: start + 3653, by: 1) {
                let parts = SerialDate.components(serial: Double(serial), system: system)
                let back = SerialDate.serial(year: parts.year, month: parts.month, day: parts.day, system: system)
                #expect(
                    back == Double(serial),
                    "\(system) serial \(serial) → \(parts.year)-\(parts.month)-\(parts.day)"
                )
            }
        }
    }
}
