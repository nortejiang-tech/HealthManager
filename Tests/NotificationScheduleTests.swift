import XCTest
@testable import HealthManager

final class NotificationScheduleTests: XCTestCase {

    func test_roundTripJson() {
        let s = NotificationScheduler.Schedule(weekdays: [2, 4, 6], hour: 9, minute: 30)
        guard let json = s.toJson() else { return XCTFail("toJson returned nil") }
        let decoded = NotificationScheduler.Schedule.fromJson(json)
        XCTAssertEqual(decoded, s)
    }

    func test_invalid_weekdayOutOfRange() {
        let s = NotificationScheduler.Schedule(weekdays: [0, 8], hour: 1, minute: 0)
        XCTAssertFalse(s.isValid)
    }

    func test_invalid_emptyWeekdays() {
        let s = NotificationScheduler.Schedule(weekdays: [], hour: 1, minute: 0)
        XCTAssertFalse(s.isValid)
    }

    func test_invalid_hourOutOfRange() {
        let s = NotificationScheduler.Schedule(weekdays: [1], hour: 24, minute: 0)
        XCTAssertFalse(s.isValid)
    }

    func test_valid() {
        XCTAssertTrue(NotificationScheduler.Schedule.defaultMorning.isValid)
    }

    func test_fromJson_malformedReturnsNil() {
        XCTAssertNil(NotificationScheduler.Schedule.fromJson("not json"))
        XCTAssertNil(NotificationScheduler.Schedule.fromJson(nil))
    }
}
