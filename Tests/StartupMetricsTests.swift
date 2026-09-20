import XCTest
@testable import HealthManager

@MainActor
final class StartupMetricsTests: XCTestCase {
    func test_recordsOrderedColdStartMilestonesWithMonotonicElapsedTime() {
        var now: TimeInterval = 100
        let metrics = StartupMetrics(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            monotonicNow: { now }
        )

        metrics.record(.environmentInitStarted)
        now = 100.125
        metrics.record(.databaseReady)
        now = 100.250
        metrics.record(.environmentReady)
        now = 100.500
        metrics.record(.recoveryReady)
        now = 100.750
        metrics.record(.initialSnapshotRequested)
        now = 101.000
        metrics.record(.snapshotAvailable)

        XCTAssertEqual(
            metrics.events.map(\.milestone),
            [
                .environmentInitStarted,
                .databaseReady,
                .environmentReady,
                .recoveryReady,
                .initialSnapshotRequested,
                .snapshotAvailable
            ]
        )
        XCTAssertEqual(metrics.events.map(\.elapsedMilliseconds), [0, 125, 250, 500, 750, 1_000])
        XCTAssertEqual(metrics.events.map(\.sequence), [1, 2, 3, 4, 5, 6])
    }

    func test_duplicateMilestoneIsIdempotent() {
        var now: TimeInterval = 5
        let metrics = StartupMetrics(monotonicNow: { now })

        metrics.record(.initialSnapshotRequested)
        now = 8
        metrics.record(.initialSnapshotRequested)

        XCTAssertEqual(metrics.events.count, 1)
        XCTAssertEqual(metrics.events.first?.elapsedMilliseconds, 0)
    }

    func test_initialSnapshotFailureCannotBeReportedAsAvailableInSameSession() {
        var now: TimeInterval = 20
        let metrics = StartupMetrics(monotonicNow: { now })

        metrics.record(.initialSnapshotRequested)
        now = 21
        metrics.record(.initialSnapshotError)
        now = 22
        metrics.record(.snapshotAvailable)

        XCTAssertEqual(metrics.events.map(\.milestone), [.initialSnapshotRequested, .initialSnapshotError])
        XCTAssertFalse(metrics.events.contains { $0.milestone == .snapshotAvailable })
    }

    func test_eachMetricsInstanceHasAnIndependentSessionID() {
        let first = StartupMetrics()
        let second = StartupMetrics()

        XCTAssertNotEqual(first.sessionID, second.sessionID)
    }
}
