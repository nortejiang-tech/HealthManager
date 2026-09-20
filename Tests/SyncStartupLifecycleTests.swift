import XCTest
@testable import HealthManager

final class SyncStartupLifecycleTests: XCTestCase {
    func test_allOrdersOfActiveAuthorizationAndRecoveryRunOneInitialFullCheck() {
        let events: [SyncStartupLifecycle.Event] = [
            .becameActive,
            .authorizationReady(true),
            .recoveryReady
        ]

        for order in permutations(events) {
            var lifecycle = SyncStartupLifecycle()
            let actions = order.flatMap { lifecycle.handle($0) }
            XCTAssertEqual(actions.filter { $0 == .startObserver }.count, 1, "order=\(order)")
            XCTAssertEqual(actions.filter { $0 == .runFullTypeCheck }.count, 1, "order=\(order)")
        }
    }

    func test_initialActiveReadinessStartsObserverAndFullCheckInSameActionBatch() {
        var lifecycle = SyncStartupLifecycle()
        XCTAssertTrue(lifecycle.handle(.recoveryReady).isEmpty)
        XCTAssertTrue(lifecycle.handle(.becameActive).isEmpty)

        XCTAssertEqual(
            lifecycle.handle(.authorizationReady(true)),
            [.startObserver, .runFullTypeCheck]
        )
    }

    func test_failedRecoveryKeepsObserverAndFullCheckClosed() {
        var lifecycle = SyncStartupLifecycle()
        let actions = [
            lifecycle.handle(.becameActive),
            lifecycle.handle(.authorizationReady(true)),
            lifecycle.handle(.recoveryFailed),
            lifecycle.handle(.becameInactive),
            lifecycle.handle(.becameActive)
        ].flatMap { $0 }

        XCTAssertTrue(actions.isEmpty)
    }

    func test_eachNewForegroundEpochRunsOnceAfterFreshAuthorizationReadiness() {
        var lifecycle = SyncStartupLifecycle()
        var actions: [SyncStartupLifecycle.Action] = []
        actions += lifecycle.handle(.recoveryReady)
        actions += lifecycle.handle(.becameActive)
        actions += lifecycle.handle(.authorizationReady(true))
        actions += lifecycle.handle(.authorizationReady(true))
        actions += lifecycle.handle(.becameActive)
        actions += lifecycle.handle(.becameInactive)
        actions += lifecycle.handle(.authorizationReady(false))
        actions += lifecycle.handle(.becameActive)
        actions += lifecycle.handle(.authorizationReady(true))

        XCTAssertEqual(actions.filter { $0 == .startObserver }.count, 1)
        XCTAssertEqual(actions.filter { $0 == .runFullTypeCheck }.count, 2)
    }

    func test_oldUserCanSeeLocalMainScreenWhileUnknownButSyncGateStaysClosed() {
        XCTAssertEqual(
            RootDestination.resolve(gate: .unknown, hasRequestedAuthorization: true),
            .main
        )
        var lifecycle = SyncStartupLifecycle()
        _ = lifecycle.handle(.recoveryReady)
        _ = lifecycle.handle(.becameActive)
        XCTAssertTrue(lifecycle.handle(.authorizationReady(false)).isEmpty)
    }

    func test_firstInstallUnknownAndNeedsRequestRemainOnboarding() {
        XCTAssertEqual(
            RootDestination.resolve(gate: .unknown, hasRequestedAuthorization: false),
            .onboarding
        )
        XCTAssertEqual(
            RootDestination.resolve(gate: .needsRequest, hasRequestedAuthorization: false),
            .onboarding
        )
    }

    func test_emptyReadTypeSetCannotBeRepresentedAsReady() {
        let emptyReadTypes: Set<String> = []
        let authorizationReady = !emptyReadTypes.isEmpty
        var lifecycle = SyncStartupLifecycle()
        _ = lifecycle.handle(.recoveryReady)
        _ = lifecycle.handle(.becameActive)

        XCTAssertTrue(lifecycle.handle(.authorizationReady(authorizationReady)).isEmpty)
        XCTAssertFalse(HealthKitTypeCatalog.allReadObjectTypes.isEmpty)
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard let first = values.first else { return [[]] }
        return permutations(Array(values.dropFirst())).flatMap { tail in
            (0...tail.count).map { index in
                var copy = tail
                copy.insert(first, at: index)
                return copy
            }
        }
    }
}
