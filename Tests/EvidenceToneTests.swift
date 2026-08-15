import XCTest
@testable import HealthManager

final class EvidenceToneTests: XCTestCase {

    // MARK: - 饮食热量证据（回归：incomplete 曾被映射成 .estimate）

    func test_caloriesIncomplete_isActionRequired() {
        XCTAssertEqual(EvidenceTone.forCalories(.incomplete), .actionRequired)
    }

    func test_caloriesComplete_isConfirmed() {
        XCTAssertEqual(EvidenceTone.forCalories(.complete(1800)), .confirmed)
    }

    func test_caloriesNoMeals_isNeutral() {
        XCTAssertEqual(EvidenceTone.forCalories(.noMeals), .neutral)
    }

    func test_dietLoadState_loadedWithIncomplete_isActionRequired() {
        XCTAssertEqual(
            EvidenceTone.forDietLoadState(.loaded, calories: .incomplete),
            .actionRequired
        )
    }

    func test_dietLoadState_failedAndStale_areActionRequired() {
        XCTAssertEqual(EvidenceTone.forDietLoadState(.failed, calories: nil), .actionRequired)
        XCTAssertEqual(EvidenceTone.forDietLoadState(.stale, calories: nil), .actionRequired)
    }

    func test_dietLoadState_loading_isNeutral() {
        XCTAssertEqual(EvidenceTone.forDietLoadState(.loading, calories: nil), .neutral)
    }

    func test_dietLoadState_loadedWithoutEvidence_isNeutral() {
        XCTAssertEqual(EvidenceTone.forDietLoadState(.loaded, calories: nil), .neutral)
        XCTAssertEqual(EvidenceTone.forDietLoadState(.loaded, calories: .noMeals), .neutral)
    }

    // MARK: - 今日页

    func test_qualityStyle_mapping() {
        XCTAssertEqual(
            EvidenceTone.forQualityStyle(.unreconciled), .neutral)
        XCTAssertEqual(
            EvidenceTone.forQualityStyle(.reconciledNoAlerts), .confirmed)
        XCTAssertEqual(
            EvidenceTone.forQualityStyle(.hasAlerts), .actionRequired)
    }

    func test_lens_prefersAlertsOverTimeline() {
        XCTAssertEqual(
            EvidenceTone.forLens(qualityStyle: .hasAlerts, hasTimelineRows: true),
            .actionRequired)
        XCTAssertEqual(
            EvidenceTone.forLens(qualityStyle: .reconciledNoAlerts, hasTimelineRows: true),
            .confirmed)
        XCTAssertEqual(
            EvidenceTone.forLens(qualityStyle: .reconciledNoAlerts, hasTimelineRows: false),
            .neutral)
    }

    // MARK: - 用药动作（回归：曾直接使用系统 .green/.red/.orange）

    func test_medicationAction_taken_isConfirmed() {
        XCTAssertEqual(EvidenceTone.forMedicationAction(.taken), .confirmed)
    }

    func test_medicationAction_skippedAndDeferred_areActionRequired() {
        XCTAssertEqual(EvidenceTone.forMedicationAction(.skipped), .actionRequired)
        XCTAssertEqual(EvidenceTone.forMedicationAction(.deferred), .actionRequired)
    }

    // MARK: - 餐食分项来源

    func test_provenance_mapping() {
        XCTAssertEqual(EvidenceTone.forProvenance(.manual), .neutral)
        XCTAssertEqual(EvidenceTone.forProvenance(.aiEstimate), .estimate)
        XCTAssertEqual(EvidenceTone.forProvenance(.nutritionDatabase), .comparison)
        XCTAssertEqual(EvidenceTone.forProvenance(.nutritionLabel), .comparison)
    }
}
