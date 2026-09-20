import XCTest
@testable import HealthManager

final class SyncRunnerIntegrationTests: XCTestCase {
    private let type = "HKQuantityTypeIdentifierBodyMass"

    func test_requestArrivingDuringActiveClaimRunsWithoutSecondManualKick() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(store: store)
        let executor = BlockingSliceExecutor(store: store, type: type)

        let first = Task {
            try await runner.submit(demand(reason: .foreground)) {
                try await executor.run()
            }
        }
        await executor.waitUntilFirstClaimIsActive()

        let second = Task {
            try await runner.submit(demand(reason: .observer)) {
                try await executor.run()
            }
        }
        try await waitForGeneration(2, store: store)
        await executor.releaseFirstSlice()

        let firstReceipt = try await first.value
        let secondReceipt = try await second.value
        let callCount = await executor.callCount()
        let isRunning = await runner.isRunning
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(firstReceipt.slices, 2)
        XCTAssertEqual(secondReceipt.slices, 2)
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 2)
        XCTAssertFalse(isRunning)
    }

    func test_requestArrivingWhileWorkerCommitsIdleStateIsNotStranded() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let quiescenceGate = QuiescenceGate()
        let runner = SyncRunner(
            store: store,
            beforeQuiescenceCommit: { await quiescenceGate.pauseOnce() }
        )
        let executor = BlockingSliceExecutor(store: store, type: type)

        let first = Task {
            try await runner.submit(demand(reason: .foreground)) {
                try await executor.run()
            }
        }
        await executor.waitUntilFirstClaimIsActive()
        await executor.releaseFirstSlice()
        await quiescenceGate.waitUntilPaused()

        let second = Task {
            try await runner.submit(demand(reason: .observer)) {
                try await executor.run()
            }
        }
        try await waitForGeneration(2, store: store)
        await quiescenceGate.release()

        let firstReceipt = try await first.value
        let secondReceipt = try await second.value
        let callCount = await executor.callCount()
        let isRunning = await runner.isRunning
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(firstReceipt.slices, 2)
        XCTAssertEqual(secondReceipt.slices, 2)
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 2)
        XCTAssertFalse(isRunning)
    }

    func test_finalDurableRecheckDrainsWorkRecordedAtIdleBoundary() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let quiescenceGate = QuiescenceGate()
        let runner = SyncRunner(
            store: store,
            beforeQuiescenceCommit: { await quiescenceGate.pauseOnce() }
        )
        let executor = BlockingSliceExecutor(store: store, type: type)

        let receiptTask = Task {
            try await runner.submit(demand(reason: .foreground)) {
                try await executor.run()
            }
        }
        await executor.waitUntilFirstClaimIsActive()
        await executor.releaseFirstSlice()
        await quiescenceGate.waitUntilPaused()

        // Model a durable callback handoff already recorded at the idle boundary. The final
        // ledger read, rather than only the actor revision counter, must keep the worker alive.
        try store.request(types: [type], reason: .observer)
        await quiescenceGate.release()

        let receipt = try await receiptTask.value
        let callCount = await executor.callCount()
        let isRunning = await runner.isRunning
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(receipt.slices, 2)
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 2)
        XCTAssertFalse(isRunning)
    }

    func test_oneThousandObserverSubmissionsCoalesceIntoTwoSlices() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(store: store)
        let executor = BlockingSliceExecutor(store: store, type: type)

        let first = Task {
            try await runner.submit(demand(reason: .observer)) { try await executor.run() }
        }
        await executor.waitUntilFirstClaimIsActive()

        let burst = Task {
            try await withThrowingTaskGroup(of: SyncRunnerReceipt.self) { group in
                for _ in 0..<1_000 {
                    group.addTask {
                        try await runner.submit(self.demand(reason: .observer)) {
                            try await executor.run()
                        }
                    }
                }
                var receipts: [SyncRunnerReceipt] = []
                for try await receipt in group { receipts.append(receipt) }
                return receipts
            }
        }
        try await waitForGeneration(1_001, store: store)
        await executor.releaseFirstSlice()

        _ = try await first.value
        let receipts = try await burst.value
        let callCount = await executor.callCount()
        let isRunning = await runner.isRunning
        XCTAssertEqual(receipts.count, 1_000)
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 1_001)
        XCTAssertFalse(isRunning)
    }

    func test_cancelledWaiterDoesNotCancelSharedDurableWorkOrLeaveRunnerBusy() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(store: store)
        let executor = BlockingSliceExecutor(store: store, type: type)

        let waiter = Task {
            try await runner.submit(demand(reason: .foreground)) { try await executor.run() }
        }
        await executor.waitUntilFirstClaimIsActive()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected cancelled waiter")
        } catch is CancellationError {}

        await executor.releaseFirstSlice()
        try await waitUntilIdle(runner)
        let isRunning = await runner.isRunning
        XCTAssertEqual(try store.work(for: type)?.completedGeneration, 1)
        XCTAssertFalse(isRunning)
    }

    func test_sliceFailureReleasesWorkerAndKeepsDemandPending() async throws {
        let database = DatabaseManager.makeInMemoryForTesting()
        let store = SyncWorkStore(database: database)
        let runner = SyncRunner(store: store)

        do {
            _ = try await runner.submit(demand(reason: .foreground)) {
                throw RunnerFixtureError.failed
            }
            XCTFail("Expected failure")
        } catch RunnerFixtureError.failed {}

        let isRunning = await runner.isRunning
        XCTAssertFalse(isRunning)
        XCTAssertTrue(try XCTUnwrap(store.work(for: type)).isPending)
    }

    private func demand(reason: SyncReason) -> SyncDemand {
        SyncDemand(types: [type], reason: reason, intentID: UUID())
    }

    private func waitForGeneration(_ expected: Int64, store: SyncWorkStore) async throws {
        for _ in 0..<20_000 {
            if try store.work(for: type)?.requestedGeneration == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for generation \(expected)")
    }

    private func waitUntilIdle(_ runner: SyncRunner) async throws {
        for _ in 0..<20_000 {
            if !(await runner.isRunning) { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for runner idle")
    }
}

private actor BlockingSliceExecutor {
    private let store: SyncWorkStore
    private let type: String
    private var calls = 0
    private var firstClaimActive = false
    private var firstClaimWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(store: SyncWorkStore, type: String) {
        self.store = store
        self.type = type
    }

    func run() async throws -> SyncRunnerSliceResult {
        let claim = try XCTUnwrap(store.claim(type: type, token: UUID()))
        calls += 1
        if calls == 1 {
            firstClaimActive = true
            firstClaimWaiters.forEach { $0.resume() }
            firstClaimWaiters.removeAll()
            if !released {
                await withCheckedContinuation { continuation in
                    releaseContinuation = continuation
                }
            }
        }
        _ = try store.commitPage(.init(
            claim: claim,
            addedRows: [],
            deletedUUIDs: [],
            newAnchorData: Data(String(calls).utf8),
            drained: true,
            calendar: .current,
            projectionVersion: 1
        ))
        return SyncRunnerSliceResult()
    }

    func waitUntilFirstClaimIsActive() async {
        if firstClaimActive { return }
        await withCheckedContinuation { continuation in
            firstClaimWaiters.append(continuation)
        }
    }

    func releaseFirstSlice() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func callCount() -> Int { calls }
}

private actor QuiescenceGate {
    private var paused = false
    private var released = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseOnce() async {
        guard !paused else { return }
        paused = true
        pauseWaiters.forEach { $0.resume() }
        pauseWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private enum RunnerFixtureError: Error {
    case failed
}
