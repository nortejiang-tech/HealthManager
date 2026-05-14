import Foundation
import GRDB

/// Manual one-shot sync (PRD F-002).
///
/// Why two passes around a user prompt:
/// - HKObserver normally fires when external apps (Garmin / 米家) write to HealthKit, but only
///   if iOS hasn't suspended us and the source app actually pushed within the last interval.
/// - When the user pulls manual sync, the *reason* is usually "I think something is missing."
///   Pass 1 sweeps whatever HK already has. Then we ask the user to open the third-party app
///   (which forces *it* to flush its queue into HealthKit), and Pass 2 picks up the new writes.
///
/// State-machine path driven by the caller (SyncEngine):
///     idle → syncingIncremental → waitingExternalSync → syncingIncremental2 → reconciling → completed
///
/// This coordinator stays UI-agnostic: it accepts a `promptForExternalSync` async closure and
/// suspends until the caller returns. SyncEngine implements that closure with a CheckedContinuation
/// that the UI (or scenePhase auto-ack) resumes.
actor ManualSyncCoordinator {

    private let incremental: IncrementalSyncCoordinator
    private let database: DatabaseManager

    init(incremental: IncrementalSyncCoordinator, database: DatabaseManager) {
        self.incremental = incremental
        self.database = database
    }

    func run(
        trigger: SyncJob.Trigger = .user,
        progress: @escaping (String) -> Void,
        promptForExternalSync: () async -> Void
    ) async throws -> SyncEngine.LastResult {

        let jobStart = Date()
        let jobId = try insertJob(trigger: trigger, startedAt: jobStart)

        progress("第 1 次拉取 HealthKit…")
        let pass1 = await incremental.executePass(progress: progress)

        progress("等待外部 App 推送至 HealthKit…")
        await promptForExternalSync()

        progress("第 2 次拉取 HealthKit…")
        let pass2 = await incremental.executePass(progress: progress)

        // Merge: sum per-type counts; report the first non-nil error so the user sees something.
        var merged = pass1.perTypeCounts
        for (k, v) in pass2.perTypeCounts {
            merged[k, default: 0] += v
        }
        let firstError = pass1.firstError ?? pass2.firstError

        // Merge per-type errors: keep the most recent occurrence per hk_type (pass 2 wins).
        // Pass 2 is the authoritative state — if pass 1 failed but pass 2 succeeded for the
        // same type, the user shouldn't see a stale error.
        var mergedErrorsByType: [String: SyncTypeError] = [:]
        for e in pass1.errors { mergedErrorsByType[e.hkType] = e }
        let pass2Successes = Set(pass2.perTypeCounts.compactMap { $0.value > 0 ? $0.key : nil })
        for k in pass2Successes { mergedErrorsByType.removeValue(forKey: k) }
        for e in pass2.errors { mergedErrorsByType[e.hkType] = e }
        let mergedErrors = Array(mergedErrorsByType.values)
            .sorted { $0.hkType < $1.hkType }

        let endedAt = Date()
        let totalSamples = merged.values.reduce(0, +)
        let succeeded = (firstError == nil)
        try finaliseJob(
            id: jobId,
            endedAt: endedAt,
            succeeded: succeeded,
            errorMessage: firstError?.localizedDescription,
            stats: merged
        )

        return SyncEngine.LastResult(
            jobId: jobId,
            jobType: .manual,
            succeeded: succeeded,
            startedAt: jobStart,
            endedAt: endedAt,
            totalSamples: totalSamples,
            perTypeCounts: merged,
            perTypeErrors: mergedErrors,
            errorMessage: firstError?.localizedDescription
        )
    }

    // MARK: - Job lifecycle (manual envelope)

    private func insertJob(trigger: SyncJob.Trigger, startedAt: Date) throws -> Int64 {
        var job = SyncJob(
            id: nil,
            jobType: .manual,
            state: .running,
            trigger: trigger,
            startedAt: Int64(startedAt.timeIntervalSince1970),
            endedAt: nil,
            errorCode: nil,
            errorMessage: nil,
            statsJson: nil,
            attempt: 1
        )
        try database.write { db in
            try job.insert(db)
        }
        guard let id = job.id else {
            throw NSError(domain: "ManualSyncCoordinator", code: -1)
        }
        return id
    }

    private func finaliseJob(
        id: Int64,
        endedAt: Date,
        succeeded: Bool,
        errorMessage: String?,
        stats: [String: Int]
    ) throws {
        let statsData = try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
        let statsJson = String(data: statsData, encoding: .utf8)
        let state = succeeded ? "succeeded" : "failed"

        try database.write { db in
            try db.execute(sql: """
                UPDATE sync_jobs
                SET state = ?, ended_at = ?, error_message = ?, stats_json = ?
                WHERE id = ?
                """, arguments: [
                    state,
                    Int64(endedAt.timeIntervalSince1970),
                    errorMessage,
                    statsJson,
                    id
                ])
        }
    }
}
