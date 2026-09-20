import Foundation

struct ManualSyncPassResult {
    let perTypeCounts: [String: Int]
    let perTypeErrors: [SyncTypeError]
    let successfulTypes: Set<String>
}

struct ManualSyncMergedResult {
    let perTypeCounts: [String: Int]
    let perTypeErrors: [SyncTypeError]
    let firstNonAuthorizationError: SyncTypeError?

    var succeeded: Bool { firstNonAuthorizationError == nil }
}

actor ManualSyncWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasResumed = false

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || hasResumed {
                    hasResumed = true
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.resume() }
        }
    }

    func resume() {
        guard !hasResumed else { return }
        hasResumed = true
        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }
}

/// Owns only the two-pass manual session/job envelope. Actual HealthKit work is supplied by
/// SyncEngine through the same SyncRunner used by observer, foreground and BG opportunities.
actor ManualSyncCoordinator {
    typealias RunPass = @Sendable () async throws -> ManualSyncPassResult

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    func run(
        trigger: SyncJob.Trigger = .user,
        progress: @escaping @Sendable (String) -> Void,
        runPass: @escaping RunPass,
        promptForExternalSync: @escaping @Sendable () async -> Void
    ) async throws -> SyncEngine.LastResult {
        let startedAt = Date()
        let jobID = try SyncJobRecorder(database: database).openJob(
            jobType: .manual,
            trigger: trigger,
            startedAt: startedAt
        )

        progress("第 1 次拉取 HealthKit…")
        let pass1 = try await runPass()
        progress("等待外部 App 推送至 HealthKit…")
        await promptForExternalSync()
        try Task.checkCancellation()
        progress("第 2 次拉取 HealthKit…")
        let pass2 = try await runPass()

        let merged = Self.merge(pass1: pass1, pass2: pass2)
        let endedAt = Date()
        let total = merged.perTypeCounts.values.reduce(0, +)
        try SyncJobRecorder(database: database).closeJob(
            id: jobID,
            endedAt: endedAt,
            succeeded: merged.succeeded,
            errorMessage: merged.firstNonAuthorizationError?.underlying,
            stats: merged.perTypeCounts
        )
        return SyncEngine.LastResult(
            jobId: jobID,
            jobType: .manual,
            succeeded: merged.succeeded,
            startedAt: startedAt,
            endedAt: endedAt,
            totalSamples: total,
            perTypeCounts: merged.perTypeCounts,
            perTypeErrors: merged.perTypeErrors,
            errorMessage: merged.firstNonAuthorizationError?.underlying
        )
    }

    static func merge(
        pass1: ManualSyncPassResult,
        pass2: ManualSyncPassResult
    ) -> ManualSyncMergedResult {
        var counts = pass1.perTypeCounts
        for (type, count) in pass2.perTypeCounts { counts[type, default: 0] += count }

        var errors = Dictionary(uniqueKeysWithValues: pass1.perTypeErrors.map { ($0.hkType, $0) })
        for type in pass2.successfulTypes { errors.removeValue(forKey: type) }
        for error in pass2.perTypeErrors { errors[error.hkType] = error }
        let ordered = errors.values.sorted { $0.hkType < $1.hkType }
        return ManualSyncMergedResult(
            perTypeCounts: counts,
            perTypeErrors: ordered,
            firstNonAuthorizationError: ordered.first(where: { !$0.isAuthDenied })
        )
    }
}
