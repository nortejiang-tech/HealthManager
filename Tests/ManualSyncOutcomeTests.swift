import XCTest
@testable import HealthManager

final class ManualSyncOutcomeTests: XCTestCase {
    func test_pass2ZeroInsertSuccessClearsPass1ErrorForSameType() {
        let pass1Error = error(type: "A", message: "pass1")
        let merged = ManualSyncCoordinator.merge(
            pass1: ManualSyncPassResult(
                perTypeCounts: ["A": 0],
                perTypeErrors: [pass1Error],
                successfulTypes: []
            ),
            pass2: ManualSyncPassResult(
                perTypeCounts: ["A": 0],
                perTypeErrors: [],
                successfulTypes: ["A"]
            )
        )

        XCTAssertTrue(merged.succeeded)
        XCTAssertTrue(merged.perTypeErrors.isEmpty)
        XCTAssertEqual(merged.perTypeCounts["A"], 0)
    }

    func test_pass2FailureForAnotherTypeRemainsInFinalResult() {
        let pass1Error = error(type: "A", message: "pass1")
        let pass2Error = error(type: "B", message: "pass2")
        let merged = ManualSyncCoordinator.merge(
            pass1: ManualSyncPassResult(
                perTypeCounts: ["A": 0, "B": 1],
                perTypeErrors: [pass1Error],
                successfulTypes: ["B"]
            ),
            pass2: ManualSyncPassResult(
                perTypeCounts: ["A": 0, "B": 0],
                perTypeErrors: [pass2Error],
                successfulTypes: ["A"]
            )
        )

        XCTAssertFalse(merged.succeeded)
        XCTAssertEqual(merged.perTypeErrors.map(\.hkType), ["B"])
        XCTAssertEqual(merged.firstNonAuthorizationError?.underlying, "pass2")
    }

    func test_authorizationOnlyErrorDoesNotFailManualSession() {
        let auth = SyncTypeError(
            hkType: "A",
            stage: .hkQuery,
            underlying: "authorization",
            isAuthDenied: true,
            occurredAt: Date()
        )
        let merged = ManualSyncCoordinator.merge(
            pass1: ManualSyncPassResult(
                perTypeCounts: ["A": 0],
                perTypeErrors: [auth],
                successfulTypes: []
            ),
            pass2: ManualSyncPassResult(
                perTypeCounts: ["A": 0],
                perTypeErrors: [auth],
                successfulTypes: []
            )
        )

        XCTAssertTrue(merged.succeeded)
        XCTAssertEqual(merged.perTypeErrors.count, 1)
    }

    func test_waiterDuplicateAcknowledgementResumesOnlyOnce() async {
        let waiter = ManualSyncWaiter()
        let task = Task { await waiter.wait() }
        await waiter.resume()
        await waiter.resume()
        await task.value

        // A second wait on the same completed one-shot waiter returns immediately and cannot
        // expose/resume the original continuation again.
        await waiter.wait()
    }

    func test_cancellingWaitReleasesContinuation() async {
        let waiter = ManualSyncWaiter()
        let task = Task { await waiter.wait() }
        task.cancel()
        await task.value
    }

    func test_parentManualJobHasOwnIDAndFinalPass2Outcome() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let coordinator = ManualSyncCoordinator(database: database)
        let counter = PassCounter()
        let result = try await coordinator.run(
            progress: { _ in },
            runPass: {
                let pass = await counter.next()
                if pass == 1 {
                    return ManualSyncPassResult(
                        perTypeCounts: ["A": 2],
                        perTypeErrors: [self.error(type: "A", message: "first")],
                        successfulTypes: []
                    )
                }
                return ManualSyncPassResult(
                    perTypeCounts: ["A": 0],
                    perTypeErrors: [],
                    successfulTypes: ["A"]
                )
            },
            promptForExternalSync: {}
        )

        XCTAssertEqual(result.jobType, .manual)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.totalSamples, 2)
        let job = try database.read { db in try SyncJob.fetchOne(db, key: result.jobId) }
        XCTAssertEqual(job?.jobType, .manual)
        XCTAssertEqual(job?.state, .succeeded)
    }

    private func error(type: String, message: String) -> SyncTypeError {
        SyncTypeError(
            hkType: type,
            stage: .hkQuery,
            underlying: message,
            isAuthDenied: false,
            occurredAt: Date()
        )
    }
}

private actor PassCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
