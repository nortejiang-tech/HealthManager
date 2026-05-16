import XCTest
@testable import HealthManager

final class WorkoutsViewTests: XCTestCase {

    func test_activityLabel_knownTypes() {
        XCTAssertEqual(WorkoutsView.label(for: 5), "棒球")
        XCTAssertEqual(WorkoutsView.label(for: 6), "篮球")
        XCTAssertEqual(WorkoutsView.label(for: 13), "骑行")
        XCTAssertEqual(WorkoutsView.label(for: 37), "跑步")
        XCTAssertEqual(WorkoutsView.label(for: 41), "足球")
        XCTAssertEqual(WorkoutsView.label(for: 46), "游泳")
        XCTAssertEqual(WorkoutsView.label(for: 74), "力量训练")
    }

    func test_activityLabel_unknown_fallsBackToRaw() {
        XCTAssertEqual(WorkoutsView.label(for: 9999), "运动 #9999")
    }

    func test_activityLabel_zero() {
        XCTAssertEqual(WorkoutsView.label(for: 0), "运动 #0")
    }
}
