import Foundation
import HealthKit
import GRDB

/// First-run + on-demand historical backfill (F-001A).
///
/// Algorithm:
/// 1. Open a `sync_jobs` row (state=running, job_type=backfill).
/// 2. For every HK sample type in `HealthKitTypeCatalog`:
///    a. `HKSampleQuery` for [now-Ndays, now].
///    b. Map → `HealthSampleRaw`; INSERT OR IGNORE (dedup on `sample_uuid`).
///    c. Append a `backfill_report` row (counts, missing flag).
/// 3. Roll up `source_coverage_daily` from the newly-ingested samples.
/// 4. Finalise the job (succeeded/failed) and return aggregated result.
///
/// Idempotency: rerunning is safe because the PK on `sample_uuid` collapses duplicates.
final class BackfillCoordinator {

    let healthKitManager: HealthKitManager
    let database: DatabaseManager

    init(healthKitManager: HealthKitManager, database: DatabaseManager) {
        self.healthKitManager = healthKitManager
        self.database = database
    }

    func run(
        days: Int,
        trigger: SyncJob.Trigger,
        progress: @escaping (String) -> Void
    ) async throws -> SyncEngine.LastResult {

        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let endDate = Date()
        let jobStart = Date()

        // 1. Open sync job
        let jobId = try insertJob(
            jobType: .backfill,
            trigger: trigger,
            startedAt: jobStart
        )

        var perTypeCounts: [String: Int] = [:]
        var firstError: Error?

        let sampleTypes = HealthKitTypeCatalog.allReadSampleTypes
        let total = sampleTypes.count

        for (index, sampleType) in sampleTypes.enumerated() {
            let identifier = sampleType.identifier
            progress("[\(index + 1)/\(total)] 拉取 \(identifier)…")

            let reportStartedAt = Date()
            do {
                let samples = try await healthKitManager.fetchSamples(
                    for: sampleType,
                    from: startDate,
                    to: endDate
                )
                let inserted = try persist(samples: samples)
                perTypeCounts[identifier] = inserted

                try recordBackfillReport(
                    jobId: jobId,
                    identifier: identifier,
                    requestedDays: days,
                    startedAt: reportStartedAt,
                    sampleCount: inserted,
                    status: .succeeded,
                    errorMessage: nil
                )
                AppLogger.shared.sync.info(
                    "Backfill \(identifier, privacy: .public): \(inserted) samples"
                )
            } catch {
                if firstError == nil { firstError = error }
                try recordBackfillReport(
                    jobId: jobId,
                    identifier: identifier,
                    requestedDays: days,
                    startedAt: reportStartedAt,
                    sampleCount: 0,
                    status: .failed,
                    errorMessage: error.localizedDescription
                )
                AppLogger.shared.sync.error(
                    "Backfill failed for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        // 3. Source coverage rollup (best-effort; failures don't fail the whole job)
        do {
            try rebuildSourceCoverage(from: startDate, to: endDate)
        } catch {
            AppLogger.shared.sync.error("Source coverage rebuild failed: \(error.localizedDescription, privacy: .public)")
        }

        // 4. Finalise the job
        let endedAt = Date()
        let totalSamples = perTypeCounts.values.reduce(0, +)
        let succeeded = (firstError == nil)
        try finaliseJob(
            id: jobId,
            endedAt: endedAt,
            succeeded: succeeded,
            errorMessage: firstError?.localizedDescription,
            stats: perTypeCounts
        )

        return SyncEngine.LastResult(
            jobId: jobId,
            jobType: .backfill,
            succeeded: succeeded,
            startedAt: jobStart,
            endedAt: endedAt,
            totalSamples: totalSamples,
            perTypeCounts: perTypeCounts,
            errorMessage: firstError?.localizedDescription
        )
    }

    // MARK: - Persistence helpers

    private func insertJob(
        jobType: SyncJob.JobType,
        trigger: SyncJob.Trigger,
        startedAt: Date
    ) throws -> Int64 {
        var job = SyncJob(
            id: nil,
            jobType: jobType,
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
            throw NSError(domain: "BackfillCoordinator", code: -1)
        }
        return id
    }

    private func persist(samples: [HKSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let ingestedAt = Date()
        let rows: [HealthSampleRaw] = samples.compactMap {
            SampleMapper.map($0, ingestedAt: ingestedAt)
        }
        guard !rows.isEmpty else { return 0 }
        try database.write { db in
            for row in rows {
                // INSERT OR IGNORE — dedup on sample_uuid PK
                try row.insert(db, onConflict: .ignore)
            }
        }
        return rows.count
    }

    private func recordBackfillReport(
        jobId: Int64,
        identifier: String,
        requestedDays: Int,
        startedAt: Date,
        sampleCount: Int,
        status: BackfillReport.Status,
        errorMessage: String?
    ) throws {
        var report = BackfillReport(
            id: nil,
            jobId: jobId,
            startedAt: Int64(startedAt.timeIntervalSince1970),
            endedAt: Int64(Date().timeIntervalSince1970),
            requestedDays: requestedDays,
            hkType: identifier,
            sampleCount: sampleCount,
            missing: sampleCount == 0,
            status: status,
            errorMessage: errorMessage,
            coverageSummaryJson: nil,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        try database.write { db in
            try report.insert(db)
        }
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

    /// Re-derives source_coverage_daily for the window using a single GROUP BY.
    /// Cheap to recompute, so we just blow away the window and re-insert.
    private func rebuildSourceCoverage(from start: Date, to end: Date) throws {
        let startEpoch = Int64(start.timeIntervalSince1970)
        let endEpoch = Int64(end.timeIntervalSince1970)
        let computedAt = Int64(Date().timeIntervalSince1970)

        try database.write { db in
            // Wipe the affected dates first, by deriving the unique date list from raw samples.
            try db.execute(sql: """
                DELETE FROM source_coverage_daily
                WHERE date IN (
                    SELECT DISTINCT strftime('%Y-%m-%d', datetime(start_at, 'unixepoch', 'localtime'))
                    FROM health_samples_raw
                    WHERE start_at BETWEEN ? AND ?
                )
                """, arguments: [startEpoch, endEpoch])

            try db.execute(sql: """
                INSERT INTO source_coverage_daily
                  (date, source_bundle_id, source_name, sample_count, hk_types_json, last_seen_at)
                SELECT
                    strftime('%Y-%m-%d', datetime(start_at, 'unixepoch', 'localtime')) AS date,
                    COALESCE(source_bundle_id, 'unknown') AS source_bundle_id,
                    MIN(source_name) AS source_name,
                    COUNT(*) AS sample_count,
                    NULL AS hk_types_json,
                    MAX(start_at) AS last_seen_at
                FROM health_samples_raw
                WHERE start_at BETWEEN ? AND ?
                GROUP BY date, source_bundle_id
                """, arguments: [startEpoch, endEpoch])

            _ = computedAt // referenced for clarity; field stored via last_seen_at above
        }
    }
}
