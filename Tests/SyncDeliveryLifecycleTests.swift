import XCTest
import HealthKit
@testable import HealthManager

final class SyncDeliveryLifecycleTests: XCTestCase {
    func test_observerAcknowledgesAppliedAndResumableDeferredOnly() {
        XCTAssertTrue(SyncDeliveryAssessment.assess(work(completed: 1)).observerMayAcknowledge)
        XCTAssertTrue(
            SyncDeliveryAssessment.assess(work(deferred: .waitForUnlock)).observerMayAcknowledge
        )
        XCTAssertTrue(
            SyncDeliveryAssessment.assess(work(deferred: .authorizationCheck)).observerMayAcknowledge
        )
        XCTAssertFalse(
            SyncDeliveryAssessment.assess(work(deferred: .repairRequired)).observerMayAcknowledge
        )
        XCTAssertFalse(
            SyncDeliveryAssessment.assess(work(deferred: .failure)).observerMayAcknowledge
        )
        XCTAssertFalse(SyncDeliveryAssessment.assess(nil).observerMayAcknowledge)
    }

    func test_backgroundOnlySucceedsWhenRequiredGenerationApplied() {
        XCTAssertTrue(SyncDeliveryAssessment.assess(work(completed: 1)).backgroundSucceeded)
        XCTAssertFalse(
            SyncDeliveryAssessment.assess(work(deferred: .waitForUnlock)).backgroundSucceeded
        )
        XCTAssertFalse(SyncDeliveryAssessment.assess(work()).backgroundSucceeded)
        XCTAssertFalse(SyncDeliveryAssessment.assess(nil).backgroundSucceeded)
    }

    func test_completionGateFinishesExactlyOnceUnderRace() {
        let recorder = CompletionRecorder()
        let gate = SyncCompletionGate { success in
            recorder.append(success)
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "sync-completion-race", attributes: .concurrent)
        for index in 0..<100 {
            group.enter()
            queue.async {
                _ = gate.finish(success: index.isMultiple(of: 2))
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(recorder.count, 1)
    }

    func test_backgroundDeliveryRetryIsFiniteAndExponential() {
        XCTAssertEqual(BackgroundDeliveryRetryPolicy.delay(afterFailedAttempt: 1), 30)
        XCTAssertEqual(BackgroundDeliveryRetryPolicy.delay(afterFailedAttempt: 2), 60)
        XCTAssertNil(BackgroundDeliveryRetryPolicy.delay(afterFailedAttempt: 3))
        XCTAssertNil(BackgroundDeliveryRetryPolicy.delay(afterFailedAttempt: 0))
    }

    func test_observerDemandContainsOnlyDeliveredType() {
        let delivered = "HKQuantityTypeIdentifierStepCount"

        XCTAssertEqual(HealthKitObserverDemand.scope(identifier: delivered), [delivered])
    }

    func test_initialObserverCoverageIsConsumedExactlyOncePerType() {
        var coverage = HealthKitObserverInitialDeliveryCoverage()
        coverage.mark("bodyMass")

        XCTAssertTrue(coverage.consume("bodyMass"))
        XCTAssertFalse(coverage.consume("bodyMass"))
        XCTAssertFalse(coverage.consume("stepCount"))
    }

    func test_readyTypeSelectionUsesPendingWorkAndPreservesCatalogOrder() throws {
        let catalog = Array(HealthKitTypeCatalog.allReadSampleTypes.prefix(3))
        XCTAssertEqual(catalog.count, 3)
        let first = catalog[0].identifier
        let second = catalog[1].identifier
        let third = catalog[2].identifier

        let selection = IncrementalSyncCoordinator.selectReadyTypes(
            from: [
                work(identifier: third),
                work(identifier: first),
                work(identifier: second, completed: 1),
                work(identifier: "com.norte.HealthManager.unknown")
            ],
            catalog: catalog
        )

        XCTAssertEqual(selection.sampleTypes.map(\.identifier), [first, third])
        XCTAssertEqual(selection.unknownIdentifiers, ["com.norte.HealthManager.unknown"])
    }

    func test_protectedDataFailureDefersRemainingTypesInsteadOfRetryingEachType() {
        let underlying = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue
        )
        let wrapped = HealthKitManager.HKError.queryFailed(underlying: underlying)

        XCTAssertTrue(IncrementalSyncCoordinator.shouldDeferRemainingTypes(after: wrapped))
        XCTAssertFalse(
            IncrementalSyncCoordinator.shouldDeferRemainingTypes(
                after: NSError(domain: "fixture", code: 99)
            )
        )
    }

    private func work(
        identifier: String = "fixture",
        requested: Int64 = 1,
        completed: Int64 = 0,
        deferred: SyncDeferredReason? = nil
    ) -> SyncTypeWork {
        SyncTypeWork(
            hkType: identifier,
            requestedGeneration: requested,
            completedGeneration: completed,
            reasonMask: SyncReason.observer.bitMask,
            deferredReason: deferred,
            retryAt: nil,
            lastCheckedAt: nil,
            lastErrorCode: nil
        )
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}
