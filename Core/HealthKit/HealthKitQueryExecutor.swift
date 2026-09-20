import Foundation

enum HealthKitQueryExecutorError: Error, Equatable {
    case timedOut
}

/// Idempotent cancellation token for one scheduled deadline.
final class HealthKitQueryDeadlineHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }
}

struct HealthKitQueryDeadlineScheduler: @unchecked Sendable {
    let schedule: (TimeInterval, @escaping @Sendable () -> Void) -> HealthKitQueryDeadlineHandle

    static let live = HealthKitQueryDeadlineScheduler { interval, action in
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.norte.HealthManager.health-query-deadline")
        )
        timer.setEventHandler(handler: action)
        timer.schedule(deadline: .now() + max(0, interval))
        timer.resume()
        return HealthKitQueryDeadlineHandle {
            timer.setEventHandler {}
            timer.cancel()
        }
    }
}

/// Executes callback-based HealthKit queries with one serialized completion gate.
/// Query registration/execute and every terminal signal are ordered on the same queue.
enum HealthKitQueryExecutor {
    static let defaultTimeout: TimeInterval = 8

    static func run<Query: AnyObject, Value>(
        timeout: TimeInterval = defaultTimeout,
        scheduler: HealthKitQueryDeadlineScheduler = .live,
        execute: @escaping (Query) -> Void,
        stop: @escaping (Query) -> Void,
        makeQuery: @escaping (@escaping (Result<Value, Error>) -> Void) -> Query
    ) async throws -> Value {
        let lifecycle = QueryLifecycle<Query, Value>(
            timeout: timeout,
            scheduler: scheduler,
            execute: execute,
            stop: stop,
            makeQuery: makeQuery
        )

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lifecycle.register(continuation)
            }
        } onCancel: {
            lifecycle.cancel()
        }
    }
}

private final class QueryLifecycle<Query: AnyObject, Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.norte.HealthManager.health-query-lifecycle")
    private let cancellationLock = NSLock()
    private var cancellationRequested = false

    private let timeout: TimeInterval
    private let scheduler: HealthKitQueryDeadlineScheduler
    private let executeQuery: (Query) -> Void
    private let stopQuery: (Query) -> Void
    private let makeQuery: (@escaping (Result<Value, Error>) -> Void) -> Query

    private var continuation: CheckedContinuation<Value, Error>?
    private var terminalResult: Result<Value, Error>?
    private var query: Query?
    private var deadline: HealthKitQueryDeadlineHandle?
    private var didExecute = false
    private var didStop = false

    init(
        timeout: TimeInterval,
        scheduler: HealthKitQueryDeadlineScheduler,
        execute: @escaping (Query) -> Void,
        stop: @escaping (Query) -> Void,
        makeQuery: @escaping (@escaping (Result<Value, Error>) -> Void) -> Query
    ) {
        self.timeout = timeout
        self.scheduler = scheduler
        self.executeQuery = execute
        self.stopQuery = stop
        self.makeQuery = makeQuery
    }

    func register(_ continuation: CheckedContinuation<Value, Error>) {
        queue.async { [self] in
            if isCancellationRequested {
                settle(.failure(CancellationError()), shouldStop: false, continuation: continuation)
                return
            }
            if let terminalResult {
                continuation.resume(with: terminalResult)
                return
            }

            self.continuation = continuation
            let query = makeQuery { [weak self] result in
                self?.finish(result)
            }
            self.query = query

            // execute runs inside the serialized gate. A synchronous callback is queued
            // behind this block, so cancellation can never stop-before-execute and then
            // allow execute to proceed afterward.
            didExecute = true
            executeQuery(query)
            deadline = scheduler.schedule(timeout) { [weak self] in
                self?.timeoutReached()
            }
        }
    }

    func cancel() {
        cancellationLock.withLock {
            cancellationRequested = true
        }
        queue.async { [self] in
            settle(.failure(CancellationError()), shouldStop: true)
        }
    }

    private var isCancellationRequested: Bool {
        cancellationLock.withLock { cancellationRequested }
    }

    private func finish(_ result: Result<Value, Error>) {
        queue.async { [self] in
            settle(result, shouldStop: false)
        }
    }

    private func timeoutReached() {
        queue.async { [self] in
            settle(.failure(HealthKitQueryExecutorError.timedOut), shouldStop: true)
        }
    }

    private func settle(
        _ result: Result<Value, Error>,
        shouldStop: Bool,
        continuation directContinuation: CheckedContinuation<Value, Error>? = nil
    ) {
        guard terminalResult == nil else { return }
        terminalResult = result
        deadline?.cancel()
        deadline = nil

        if shouldStop, didExecute, !didStop, let query {
            didStop = true
            stopQuery(query)
        }

        let target = directContinuation ?? continuation
        continuation = nil
        self.query = nil
        target?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
