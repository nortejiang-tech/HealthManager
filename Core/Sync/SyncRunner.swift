import Foundation

struct SyncRunnerSliceResult {
    let jobID: Int64?
    let startedAt: Date
    let endedAt: Date
    let perTypeCounts: [String: Int]
    let perTypeErrors: [SyncTypeError]
    let errorMessage: String?

    init(
        jobID: Int64? = nil,
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        perTypeCounts: [String: Int] = [:],
        perTypeErrors: [SyncTypeError] = [],
        errorMessage: String? = nil
    ) {
        self.jobID = jobID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.perTypeCounts = perTypeCounts
        self.perTypeErrors = perTypeErrors
        self.errorMessage = errorMessage
    }
}

struct SyncRunnerReceipt {
    let lastJobID: Int64?
    let startedAt: Date
    let endedAt: Date
    let perTypeCounts: [String: Int]
    let perTypeErrors: [SyncTypeError]
    let firstErrorMessage: String?
    let slices: Int
    let hasPending: Bool
    let deferredTypes: Set<String>
    let changedDates: Set<String>
}

enum SyncRunnerError: Error {
    case sliceLimitReached(Int)
    case restoreInProgress
}

/// The sole owner of the incremental worker handle.
///
/// Every submission first records durable generation demand. Reentrant calls while a slice is
/// awaiting HealthKit only add generations and wait on the same worker. When a slice completes,
/// the worker re-reads the durable queue; demand that arrived during the query therefore runs
/// without a second foreground/manual invocation.
actor SyncRunner {
    typealias RunSlice = @Sendable () async throws -> SyncRunnerSliceResult
    typealias BeforeQuiescenceCommit = @Sendable () async -> Void

    private struct Accumulator {
        var lastJobID: Int64?
        var startedAt = Date()
        var endedAt = Date()
        var counts: [String: Int] = [:]
        var errorsByType: [String: SyncTypeError] = [:]
        var firstErrorMessage: String?
        var slices = 0
        var changedDates: Set<String> = []

        mutating func append(_ result: SyncRunnerSliceResult) {
            if slices == 0 { startedAt = result.startedAt }
            endedAt = result.endedAt
            lastJobID = result.jobID ?? lastJobID
            for (type, count) in result.perTypeCounts { counts[type, default: 0] += count }
            for error in result.perTypeErrors { errorsByType[error.hkType] = error }
            if firstErrorMessage == nil { firstErrorMessage = result.errorMessage }
            slices += 1
        }

        mutating func append(_ projection: ProjectionRunResult) {
            changedDates.formUnion(projection.changedDates)
        }
    }

    private let store: SyncWorkStore
    private let projectionWorker: ProjectionWorker?
    private let maximumSlicesPerWorker: Int
    private let beforeQuiescenceCommit: BeforeQuiescenceCommit
    private var workerTask: Task<Void, Never>?
    private var restoreRequested = false
    private var waiters: [UUID: CheckedContinuation<SyncRunnerReceipt, Error>] = [:]
    private var accumulator = Accumulator()
    private var submissionRevision: UInt64 = 0

    init(
        store: SyncWorkStore,
        projectionWorker: ProjectionWorker? = nil,
        maximumSlicesPerWorker: Int = 128,
        beforeQuiescenceCommit: @escaping BeforeQuiescenceCommit = {}
    ) {
        self.store = store
        self.projectionWorker = projectionWorker
        self.maximumSlicesPerWorker = max(1, maximumSlicesPerWorker)
        self.beforeQuiescenceCommit = beforeQuiescenceCommit
    }

    var isRunning: Bool { workerTask != nil }

    /// Persist demand without starting a worker. Used while a mutually-exclusive legacy
    /// operation (current backfill/manual compatibility path) owns the write surface.
    func enqueue(_ demand: SyncDemand) throws {
        try store.request(types: demand.types, reason: demand.reason)
        submissionRevision &+= 1
    }

    /// Stop creating writer opportunities, cancel the current slice and wait until its
    /// page transaction has either committed or rolled back. The durable marker is written
    /// only after that drain, immediately before BackupImporter is allowed to mutate content.
    func beginRestore() async throws {
        restoreRequested = true
        if let workerTask {
            workerTask.cancel()
            await workerTask.value
        }
        try store.setRestoreInProgress(true, pausedReason: "backup_restore")
    }

    /// Success reopens execution. Failure intentionally leaves both the in-memory pause and
    /// durable marker in place so process death cannot silently resume writers mid-restore.
    func finishRestore(success: Bool) throws {
        guard success else { return }
        try store.setRestoreInProgress(false, pausedReason: nil)
        restoreRequested = false
    }

    func submit(
        _ demand: SyncDemand,
        runSlice: @escaping RunSlice
    ) async throws -> SyncRunnerReceipt {
        try store.request(types: demand.types, reason: demand.reason)
        submissionRevision &+= 1
        let durableRestoreInProgress = try store.runtimeState().restoreInProgress
        if restoreRequested || durableRestoreInProgress {
            throw SyncRunnerError.restoreInProgress
        }
        let waiterID = UUID()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                if workerTask == nil, !restoreRequested {
                    accumulator = Accumulator()
                    workerTask = Task { [weak self] in
                        await self?.runWorker(runSlice: runSlice)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func runWorker(runSlice: @escaping RunSlice) async {
        do {
            var iterations = 0
            while iterations < maximumSlicesPerWorker {
                try Task.checkCancellation()
                let revisionAtProbe = submissionRevision
                let ready = try store.pendingWork()
                let projectionWasPending = try await projectionWorker?.hasPending() ?? false
                guard !ready.isEmpty || projectionWasPending else {
                    if await finishWorker(error: nil, onlyIfRevision: revisionAtProbe) {
                        return
                    }
                    // A submit landed after the empty probe but before the worker committed
                    // its idle state. Keep the same worker and waiters alive, then re-read the
                    // durable queue so the new generation cannot be stranded until relaunch.
                    continue
                }

                if !ready.isEmpty {
                    let result = try await runSlice()
                    accumulator.append(result)
                }
                if let projectionWorker {
                    let projection = try await projectionWorker.runBatch()
                    accumulator.append(projection)
                }
                iterations += 1
                await Task.yield()
            }
            _ = await finishWorker(error: SyncRunnerError.sliceLimitReached(maximumSlicesPerWorker))
        } catch {
            _ = await finishWorker(error: error)
        }
    }

    @discardableResult
    private func finishWorker(
        error: Error?,
        onlyIfRevision expectedRevision: UInt64? = nil
    ) async -> Bool {
        let allWork = (try? store.pendingWork(now: .distantFuture)) ?? []
        let hasPending = allWork.contains(where: \.isPending)
        var deferred: Set<String> = []
        if let types = try? allKnownTypes() {
            for type in types {
                if let work = try? store.work(for: type), work.isPending, work.deferredReason != nil {
                    deferred.insert(type)
                }
            }
        }
        let projectionPending = (try? await projectionWorker?.hasPending()) ?? false
        if expectedRevision != nil {
            await beforeQuiescenceCommit()
        }
        if let expectedRevision, expectedRevision != submissionRevision {
            return false
        }
        if expectedRevision != nil,
           let readyAfterProbe = try? store.pendingWork(),
           !readyAfterProbe.isEmpty {
            // The durable ledger is the final authority. This also covers work recorded by
            // an older in-flight callback whose actor revision was already observed before
            // the empty probe. There is no suspension between this check and committing idle,
            // so a later `submit` will see `workerTask == nil` and start a fresh worker.
            return false
        }
        let receipt = SyncRunnerReceipt(
            lastJobID: accumulator.lastJobID,
            startedAt: accumulator.startedAt,
            endedAt: accumulator.endedAt,
            perTypeCounts: accumulator.counts,
            perTypeErrors: Array(accumulator.errorsByType.values).sorted { $0.hkType < $1.hkType },
            firstErrorMessage: accumulator.firstErrorMessage,
            slices: accumulator.slices,
            hasPending: hasPending || !deferred.isEmpty || projectionPending,
            deferredTypes: deferred,
            changedDates: accumulator.changedDates
        )
        let currentWaiters = waiters.values
        waiters.removeAll()
        workerTask = nil
        for waiter in currentWaiters {
            if let error { waiter.resume(throwing: error) }
            else { waiter.resume(returning: receipt) }
        }
        return true
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        // Shared work is intentionally not cancelled: its durable demand may belong to other
        // observer/BG/foreground waiters, and a caller cancellation cannot discard it.
    }

    private func allKnownTypes() throws -> [String] {
        // `pendingWork(.distantFuture)` includes retryable future work but excludes explicit
        // authorization/repair deferrals. Catalog identifiers cover those durable rows.
        Array(Set(HealthKitTypeCatalog.allReadSampleTypes.map(\.identifier)))
    }
}
