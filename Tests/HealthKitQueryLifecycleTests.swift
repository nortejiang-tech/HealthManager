import XCTest
@testable import HealthManager

final class HealthKitQueryLifecycleTests: XCTestCase {
    private final class FakeQuery {}

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func read<T>(_ body: (Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(value)
        }

        func update(_ body: (inout Value) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&value)
        }
    }

    private final class FakeDeadlineClock: @unchecked Sendable {
        private struct Entry {
            var cancelled: Bool
            let action: @Sendable () -> Void
        }

        private let entries = Locked<[Entry]>([])

        var scheduler: HealthKitQueryDeadlineScheduler {
            HealthKitQueryDeadlineScheduler { [entries] _, action in
                let index = entries.read(\.count)
                entries.update { $0.append(Entry(cancelled: false, action: action)) }
                return HealthKitQueryDeadlineHandle {
                    entries.update { values in
                        guard values.indices.contains(index) else { return }
                        values[index].cancelled = true
                    }
                }
            }
        }

        var cancelledCount: Int {
            entries.read { $0.filter(\.cancelled).count }
        }

        func fireActiveDeadlines() {
            let actions = entries.read { values in
                values.filter { !$0.cancelled }.map(\.action)
            }
            actions.forEach { $0() }
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private let arrived: XCTestExpectation

        init(arrived: XCTestExpectation) {
            self.arrived = arrived
        }

        func wait() async {
            arrived.fulfill()
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    func test_cancelledBeforeExecutorRegistrationNeverExecutesQuery() async {
        let arrived = expectation(description: "task reached gate")
        let gate = Gate(arrived: arrived)
        let executeCount = Locked(0)
        let stopCount = Locked(0)

        let task = Task<Int, Error> {
            await gate.wait()
            return try await HealthKitQueryExecutor.run(
                execute: { (_: FakeQuery) in executeCount.update { $0 += 1 } },
                stop: { (_: FakeQuery) in stopCount.update { $0 += 1 } },
                makeQuery: { _ in FakeQuery() }
            )
        }

        await fulfillment(of: [arrived], timeout: 1)
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(executeCount.read { $0 }, 0)
        XCTAssertEqual(stopCount.read { $0 }, 0)
    }

    func test_cancellationAfterExecuteStopsExactlyOnceAndCancelsDeadline() async {
        let executed = expectation(description: "query executed")
        let clock = FakeDeadlineClock()
        let executeCount = Locked(0)
        let stopCount = Locked(0)

        let task = Task<Int, Error> {
            try await HealthKitQueryExecutor.run(
                scheduler: clock.scheduler,
                execute: { (_: FakeQuery) in
                    executeCount.update { $0 += 1 }
                    executed.fulfill()
                },
                stop: { (_: FakeQuery) in stopCount.update { $0 += 1 } },
                makeQuery: { _ in FakeQuery() }
            )
        }

        await fulfillment(of: [executed], timeout: 1)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(executeCount.read { $0 }, 1)
        XCTAssertEqual(stopCount.read { $0 }, 1)
        XCTAssertEqual(clock.cancelledCount, 1)
    }

    func test_timeoutStopsOnceAndIgnoresLateAndDuplicateCallbacks() async {
        let executed = expectation(description: "query executed")
        let clock = FakeDeadlineClock()
        let stopCount = Locked(0)
        let callback = Locked<((Result<Int, Error>) -> Void)?>(nil)

        let task = Task<Int, Error> {
            try await HealthKitQueryExecutor.run(
                scheduler: clock.scheduler,
                execute: { (_: FakeQuery) in executed.fulfill() },
                stop: { (_: FakeQuery) in stopCount.update { $0 += 1 } },
                makeQuery: { completion in
                    callback.update { $0 = completion }
                    return FakeQuery()
                }
            )
        }

        await fulfillment(of: [executed], timeout: 1)
        clock.fireActiveDeadlines()

        do {
            _ = try await task.value
            XCTFail("expected timeout")
        } catch let error as HealthKitQueryExecutorError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        callback.read { $0 }?(.success(1))
        callback.read { $0 }?(.success(2))
        XCTAssertEqual(stopCount.read { $0 }, 1)
        XCTAssertEqual(clock.cancelledCount, 1)
    }

    func test_firstCallbackWinsAndDuplicateCallbackIsIgnored() async throws {
        let executed = expectation(description: "query executed")
        let clock = FakeDeadlineClock()
        let stopCount = Locked(0)
        let callback = Locked<((Result<Int, Error>) -> Void)?>(nil)

        let task = Task<Int, Error> {
            try await HealthKitQueryExecutor.run(
                scheduler: clock.scheduler,
                execute: { (_: FakeQuery) in executed.fulfill() },
                stop: { (_: FakeQuery) in stopCount.update { $0 += 1 } },
                makeQuery: { completion in
                    callback.update { $0 = completion }
                    return FakeQuery()
                }
            )
        }

        await fulfillment(of: [executed], timeout: 1)
        callback.read { $0 }?(.success(41))
        callback.read { $0 }?(.success(99))

        let value = try await task.value
        XCTAssertEqual(value, 41)
        XCTAssertEqual(stopCount.read { $0 }, 0)
        XCTAssertEqual(clock.cancelledCount, 1)
    }

    func test_completionAndCancellationRaceSettlesOnlyOnce() async {
        for _ in 0..<50 {
            let executed = expectation(description: "query executed")
            let clock = FakeDeadlineClock()
            let stopCount = Locked(0)
            let callback = Locked<((Result<Int, Error>) -> Void)?>(nil)

            let task = Task<Int, Error> {
                try await HealthKitQueryExecutor.run(
                    scheduler: clock.scheduler,
                    execute: { (_: FakeQuery) in executed.fulfill() },
                    stop: { (_: FakeQuery) in stopCount.update { $0 += 1 } },
                    makeQuery: { completion in
                        callback.update { $0 = completion }
                        return FakeQuery()
                    }
                )
            }

            await fulfillment(of: [executed], timeout: 1)
            DispatchQueue.global().async {
                callback.read { $0 }?(.success(7))
            }
            task.cancel()

            do {
                let value = try await task.value
                XCTAssertEqual(value, 7)
                XCTAssertEqual(stopCount.read { $0 }, 0)
            } catch is CancellationError {
                XCTAssertEqual(stopCount.read { $0 }, 1)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(clock.cancelledCount, 1)
        }
    }
}
