import XCTest
@testable import HealthManager

final class SyncStateMachineTests: XCTestCase {

    func test_idleAndStartBackfill_goesToBackfilling() throws {
        var sm = SyncStateMachine()
        try sm.handle(.startBackfill)
        XCTAssertEqual(sm.phase, .backfilling)
    }

    func test_backfillHappyPath_completes() throws {
        var sm = SyncStateMachine()
        try sm.handle(.startBackfill)
        try sm.handle(.reconcileFinished)
        XCTAssertEqual(sm.phase, .completed)
        XCTAssertTrue(sm.isTerminal)
    }

    func test_incrementalHappyPath_completes() throws {
        var sm = SyncStateMachine()
        try sm.handle(.startIncremental)
        XCTAssertEqual(sm.phase, .syncingIncremental)
        try sm.handle(.incrementalFinished)
        XCTAssertEqual(sm.phase, .reconciling)
        try sm.handle(.reconcileFinished)
        XCTAssertEqual(sm.phase, .completed)
    }

    func test_manualHappyPath_throughExternal() throws {
        var sm = SyncStateMachine()
        try sm.handle(.startManual)
        XCTAssertEqual(sm.phase, .syncingIncremental)
        try sm.handle(.userPromptedForExternal)
        XCTAssertEqual(sm.phase, .waitingExternalSync)
        try sm.handle(.userResumedFromExternal)
        XCTAssertEqual(sm.phase, .syncingIncremental2)
        try sm.handle(.incrementalFinished)
        XCTAssertEqual(sm.phase, .reconciling)
        try sm.handle(.reconcileFinished)
        XCTAssertEqual(sm.phase, .completed)
    }

    func test_invalidTransition_throws() {
        var sm = SyncStateMachine()
        XCTAssertThrowsError(try sm.handle(.incrementalFinished)) { err in
            guard case SyncStateMachine.TransitionError.invalidTransition = err else {
                return XCTFail("expected invalidTransition")
            }
        }
    }

    func test_failFromAnyActivePhase() throws {
        for start: SyncStateMachine.Event in [.startBackfill, .startIncremental] {
            var sm = SyncStateMachine()
            try sm.handle(start)
            try sm.handle(.fail)
            XCTAssertEqual(sm.phase, .failed)
            XCTAssertTrue(sm.isTerminal)
        }
    }

    func test_resetFromAnyPhase() throws {
        var sm = SyncStateMachine()
        try sm.handle(.startManual)
        try sm.handle(.userPromptedForExternal)
        try sm.handle(.reset)
        XCTAssertEqual(sm.phase, .idle)
    }

    func test_requestingAuthThenBackfill() throws {
        var sm = SyncStateMachine()
        try sm.handle(.authRequested)
        XCTAssertEqual(sm.phase, .requestingAuth)
        try sm.handle(.startBackfill)
        XCTAssertEqual(sm.phase, .backfilling)
    }
}
