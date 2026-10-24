import XCTest
@testable import HealthManager

final class GarminPresentationTests: XCTestCase {
    private func record(_ metric: GarminMetric = .sleep, date: String = "2026-10-24",
                        value: Double?, state: String = "available", duration: Double? = nil) -> GarminMetricRecord {
        var payload = GarminMetricPayload()
        payload.values["primary"] = value
        payload.values["sleepTimeSeconds"] = duration
        return GarminMetricRecord(id: "\(metric.rawValue)-\(date)", date: date, metric: metric,
                                  payload: payload.values.isEmpty ? nil : payload,
                                  fetchedAt: Date(), lastAttemptAt: Date(), state: state)
    }

    func testNewDayFailureShowsPriorValueAndLatestFailureSeparately() {
        let display = GarminPresentation(metric: .sleep, records: [
            record(date: "2026-10-23", value: 81), record(value: nil, state: "error")
        ])
        XCTAssertEqual(display.value, 81)
        XCTAssertEqual(display.displayed?.date, "2026-10-23")
        XCTAssertEqual(display.latestAttempt?.date, "2026-10-24")
        XCTAssertEqual(display.status, "历史值 · 同步未完成")
    }

    func testEmptyNewDayDoesNotEraseOrPresentOldScoreAsCurrent() {
        let display = GarminPresentation(metric: .sleep, records: [
            record(value: nil, state: "noData", duration: 28_800), record(date: "2026-10-23", value: 80)
        ])
        XCTAssertEqual(display.value, 80)
        XCTAssertEqual(display.status, "历史值 · 新数据未到")
    }

    func testRealZeroScoreIsNotMissingOrReplacedByOlderNonzeroValue() {
        let display = GarminPresentation(metric: .stress, records: [
            record(.stress, date: "2026-10-23", value: 50), record(.stress, value: 0)
        ])
        XCTAssertEqual(display.value, 0)
        XCTAssertEqual(display.displayed?.date, "2026-10-24")
        XCTAssertEqual(display.status, "Garmin Connect")
    }

    func testDurationOnlyDoesNotBecomeASleepScoreOrUseAnotherMetric() {
        let display = GarminPresentation(metric: .sleep, records: [
            record(.bodyBattery, value: 95), record(value: nil, duration: 28_800)
        ])
        XCTAssertNil(display.value)
        XCTAssertEqual(display.status, "已有时长 · 暂无评分")
        XCTAssertEqual(display.displayed?.metric, .sleep)
    }

    func testRetainedSameDayValueKeepsRefreshFailureVisible() {
        let display = GarminPresentation(metric: .hrv, records: [record(.hrv, value: 64, state: "error")])
        XCTAssertEqual(display.value, 64)
        XCTAssertEqual(display.status, "历史值 · 同步未完成")
        XCTAssertEqual(GarminPresentation(metric: .hrv, records: []).status, "暂无数据")
    }
}
