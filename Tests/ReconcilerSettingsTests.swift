import XCTest
@testable import HealthManager

final class ReconcilerSettingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ReconcilerSettings.resetToDefaults()
    }

    override func tearDown() {
        ReconcilerSettings.resetToDefaults()
        super.tearDown()
    }

    func test_defaults() {
        XCTAssertEqual(ReconcilerSettings.completenessThreshold, 0.75, accuracy: 1e-9)
        XCTAssertEqual(ReconcilerSettings.conflictMinSources, 2)
        XCTAssertEqual(ReconcilerSettings.consecutiveMissingForCritical, 3)
        XCTAssertEqual(ReconcilerSettings.defaultWindowDays, 7)
        XCTAssertEqual(ReconcilerSettings.coreMetrics, ReconcilerSettings.defaultCoreMetrics)
    }

    func test_setAndReadBack() {
        ReconcilerSettings.completenessThreshold = 0.6
        ReconcilerSettings.conflictMinSources = 3
        ReconcilerSettings.consecutiveMissingForCritical = 5
        ReconcilerSettings.defaultWindowDays = 14

        XCTAssertEqual(ReconcilerSettings.completenessThreshold, 0.6, accuracy: 1e-9)
        XCTAssertEqual(ReconcilerSettings.conflictMinSources, 3)
        XCTAssertEqual(ReconcilerSettings.consecutiveMissingForCritical, 5)
        XCTAssertEqual(ReconcilerSettings.defaultWindowDays, 14)
    }

    func test_completenessClamped() {
        ReconcilerSettings.completenessThreshold = 5.0
        XCTAssertLessThanOrEqual(ReconcilerSettings.completenessThreshold, 1.0)
        ReconcilerSettings.completenessThreshold = -1.0
        XCTAssertGreaterThanOrEqual(ReconcilerSettings.completenessThreshold, 0.1)
    }

    func test_conflictMinSourcesClampedUp() {
        ReconcilerSettings.conflictMinSources = 0
        XCTAssertGreaterThanOrEqual(ReconcilerSettings.conflictMinSources, 2)
        ReconcilerSettings.conflictMinSources = 100
        XCTAssertLessThanOrEqual(ReconcilerSettings.conflictMinSources, 10)
    }

    func test_configReadsCurrentDefaults() {
        ReconcilerSettings.completenessThreshold = 0.5
        ReconcilerSettings.defaultWindowDays = 21
        let cfg = DailyReconciler.Config.fromUserDefaults()
        XCTAssertEqual(cfg.completenessWarningThreshold, 0.5, accuracy: 1e-9)
        XCTAssertEqual(cfg.defaultWindowDays, 21)
    }
}
