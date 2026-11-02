import XCTest
@testable import UsageBar

final class ClockTextTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testSameDayIsATimeOnly() {
        let now = date(1, 23, 50)
        XCTAssertEqual(ClockText.at(date(1, 23, 59), relativeTo: now, uses24HourClock: true, calendar: calendar), "at 23:59")
        XCTAssertEqual(ClockText.from(date(1, 9, 5), relativeTo: now, uses24HourClock: true, calendar: calendar), "09:05")
    }

    func testRetryAfterMidnightSaysTomorrow() {
        let now = date(1, 23, 50)
        XCTAssertEqual(
            ClockText.at(date(2, 0, 19), relativeTo: now, uses24HourClock: true, calendar: calendar),
            "tomorrow at 00:19"
        )
    }

    func testFollowsTheTwelveHourClock() {
        let now = date(1, 23, 50)
        XCTAssertEqual(
            ClockText.at(date(2, 0, 19), relativeTo: now, uses24HourClock: false, calendar: calendar),
            "tomorrow at 12:19 AM"
        )
        XCTAssertEqual(ClockText.from(date(1, 15, 4), relativeTo: now, uses24HourClock: false, calendar: calendar), "3:04 PM")
    }

    func testOlderDaysUseEnglishWeekdayThenDate() {
        let now = date(5, 10, 0)
        XCTAssertEqual(ClockText.from(date(4, 22, 0), relativeTo: now, uses24HourClock: true, calendar: calendar), "yesterday 22:00")
        XCTAssertEqual(ClockText.from(date(2, 8, 30), relativeTo: now, uses24HourClock: true, calendar: calendar), "Mon 08:30")
        XCTAssertEqual(ClockText.at(date(2, 8, 30), relativeTo: now, uses24HourClock: true, calendar: calendar), "Mon at 08:30")
        XCTAssertEqual(
            ClockText.at(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 10))!,
                relativeTo: now,
                uses24HourClock: true,
                calendar: calendar
            ),
            "on Oct 16 at 10:00"
        )
    }
}
