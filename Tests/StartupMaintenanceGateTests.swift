import XCTest
@testable import HealthManager

final class StartupMaintenanceGateTests: XCTestCase {
    func test_foregroundMaintenanceWaitsForSuccessfulInitialSnapshot() {
        var gate = StartupMaintenanceGate()
        XCTAssertTrue(gate.handle(.foregroundRequested).isEmpty)
        XCTAssertFalse(gate.isReleased)

        XCTAssertEqual(gate.handle(.snapshotSettled(.success)), [.runAfterSnapshot])
        XCTAssertTrue(gate.isReleased)
    }

    func test_failedInitialSnapshotStillReleasesMaintenance() {
        var gate = StartupMaintenanceGate()
        _ = gate.handle(.foregroundRequested)

        XCTAssertEqual(gate.handle(.snapshotSettled(.failure)), [.runAfterSnapshot])
        XCTAssertTrue(gate.isReleased)
    }

    func test_snapshotMaySettleBeforeSceneBecomesActive() {
        var gate = StartupMaintenanceGate()
        XCTAssertTrue(gate.handle(.snapshotSettled(.success)).isEmpty)

        XCTAssertEqual(gate.handle(.foregroundRequested), [.runAfterSnapshot])
        XCTAssertTrue(gate.isReleased)
    }

    func test_backgroundLaunchDoesNotWaitForDashboardCreation() {
        var gate = StartupMaintenanceGate()

        XCTAssertEqual(gate.handle(.backgroundOpportunity), [.runInBackground])
        XCTAssertTrue(gate.isReleased)
    }

    func test_repeatedActiveAndRefreshEventsDoNotStartStartupMaintenanceTwice() {
        var gate = StartupMaintenanceGate()
        XCTAssertTrue(gate.handle(.foregroundRequested).isEmpty)
        XCTAssertTrue(gate.handle(.foregroundRequested).isEmpty)
        XCTAssertEqual(gate.handle(.snapshotSettled(.success)), [.runAfterSnapshot])
        XCTAssertTrue(gate.handle(.snapshotSettled(.failure)).isEmpty)
        XCTAssertTrue(gate.handle(.foregroundRequested).isEmpty)
        XCTAssertTrue(gate.handle(.backgroundOpportunity).isEmpty)
    }

    func test_projectionCatchUpUsesRawEvidenceAndPreservesBackupOnlyAggregates() {
        XCTAssertFalse(AggregateCatchUpDecision(
            hasRawSamples: false,
            hasActivityProjection: true,
            hasBodyProjection: true,
            storedVersion: 0,
            targetVersion: 4
        ).needsCatchUp)

        XCTAssertTrue(AggregateCatchUpDecision(
            hasRawSamples: true,
            hasActivityProjection: true,
            hasBodyProjection: true,
            storedVersion: 3,
            targetVersion: 4
        ).needsCatchUp)

        XCTAssertFalse(AggregateCatchUpDecision(
            hasRawSamples: true,
            hasActivityProjection: true,
            hasBodyProjection: true,
            storedVersion: 4,
            targetVersion: 4
        ).needsCatchUp)
    }
}
