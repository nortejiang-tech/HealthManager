import XCTest
@testable import HealthManager

final class SyncSchedulingStateTests: XCTestCase {
    private let tokenA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let tokenB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    func test_idleDemandBecomesOneClaimedType() throws {
        var state = SyncSchedulingState()
        let intent = UUID()

        XCTAssertTrue(try state.submit(.init(types: ["A"], reason: .observer, intentID: intent)))
        XCTAssertEqual(state.pendingTypes, ["A"])
        XCTAssertFalse(state.isRunning)

        let claim = try XCTUnwrap(state.claimNext(token: tokenA))
        XCTAssertEqual(claim.token, tokenA)
        XCTAssertEqual(claim.capturedGeneration, ["A": 1])
        XCTAssertTrue(state.isRunning)
    }

    func test_newDemandForClaimedTypeRemainsPendingAfterCapturedGenerationCompletes() throws {
        var state = SyncSchedulingState()
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        let claim = try XCTUnwrap(state.claimNext(token: tokenA))

        try state.submit(.init(types: ["A"], reason: .foreground, intentID: UUID()))
        try state.complete(claim)

        XCTAssertEqual(state.requestedGeneration["A"], 2)
        XCTAssertEqual(state.completedGeneration["A"], 1)
        XCTAssertEqual(state.pendingTypes, ["A"])
        XCTAssertFalse(state.isRunning)
    }

    func test_newUnclaimedTypeGetsFairTurnBeforeRequeuedClaimedType() throws {
        var state = SyncSchedulingState()
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        let first = try XCTUnwrap(state.claimNext(token: tokenA))

        try state.submit(.init(types: ["B"], reason: .background, intentID: UUID()))
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        try state.complete(first)

        let second = try XCTUnwrap(state.claimNext(token: tokenB))
        XCTAssertEqual(Set(second.capturedGeneration.keys), ["B"])
    }

    func test_duplicateIntentIsIdempotent() throws {
        var state = SyncSchedulingState()
        let intent = UUID()
        let demand = SyncDemand(types: ["A", "B"], reason: .foreground, intentID: intent)

        XCTAssertTrue(try state.submit(demand))
        XCTAssertFalse(try state.submit(demand))

        XCTAssertEqual(state.requestedGeneration, ["A": 1, "B": 1])
        XCTAssertEqual(state.pendingTypes, ["A", "B"])
    }

    func test_thousandEventsRemainOnePendingTypeSet() throws {
        var state = SyncSchedulingState()

        for _ in 0..<1_000 {
            try state.submit(.init(types: ["A", "B"], reason: .observer, intentID: UUID()))
        }

        XCTAssertEqual(state.pendingTypes, ["A", "B"])
        XCTAssertEqual(state.requestedGeneration, ["A": 1_000, "B": 1_000])
    }

    func test_mismatchedTokenCannotReleaseActiveWorker() throws {
        var state = SyncSchedulingState()
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        let claim = try XCTUnwrap(state.claimNext(token: tokenA))
        let wrongClaim = SyncClaim(token: tokenB, capturedGeneration: claim.capturedGeneration)

        XCTAssertThrowsError(try state.complete(wrongClaim)) { error in
            XCTAssertEqual(error as? SyncSchedulingError, .tokenMismatch(expected: self.tokenA, actual: self.tokenB))
        }
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.activeToken, tokenA)
        XCTAssertEqual(state.completedGeneration["A"], nil)
    }

    func test_generationOverflowIsAtomic() throws {
        var state = SyncSchedulingState(
            requestedGeneration: ["A": 2, "B": .max],
            completedGeneration: ["A": 1, "B": .max - 1]
        )
        let before = state

        XCTAssertThrowsError(
            try state.submit(.init(types: ["A", "B"], reason: .observer, intentID: UUID()))
        ) { error in
            XCTAssertEqual(error as? SyncSchedulingError, .generationOverflow(type: "B"))
        }

        XCTAssertEqual(state, before)
    }

    func test_allDeferredWorkDoesNotCreateBusyLoop() throws {
        var state = SyncSchedulingState()
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        let claim = try XCTUnwrap(state.claimNext(token: tokenA))

        try state.release(claim, deferring: ["A"])

        XCTAssertEqual(state.pendingTypes, ["A"])
        XCTAssertEqual(state.deferredTypes, ["A"])
        XCTAssertTrue(state.readyTypes.isEmpty)
        XCTAssertNil(state.claimNext(token: tokenB))
        XCTAssertFalse(state.isRunning)

        state.resume(["A"])
        XCTAssertEqual(state.readyTypes, ["A"])
        XCTAssertNotNil(state.claimNext(token: tokenB))
    }

    func test_controlledABAASequenceCompletesOnlyCapturedGenerations() throws {
        var state = SyncSchedulingState()
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        let firstA = try XCTUnwrap(state.claimNext(token: tokenA))

        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        try state.submit(.init(types: ["B"], reason: .observer, intentID: UUID()))
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        try state.submit(.init(types: ["A"], reason: .observer, intentID: UUID()))
        try state.complete(firstA)

        XCTAssertEqual(state.requestedGeneration, ["A": 4, "B": 1])
        XCTAssertEqual(state.completedGeneration["A"], 1)
        XCTAssertEqual(state.pendingTypes, ["A", "B"])

        let b = try XCTUnwrap(state.claimNext(token: tokenB))
        XCTAssertEqual(b.capturedGeneration, ["B": 1])
        try state.complete(b)

        let nextA = try XCTUnwrap(state.claimNext(token: tokenA))
        XCTAssertEqual(nextA.capturedGeneration, ["A": 4])
    }
}
