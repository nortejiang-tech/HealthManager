import Foundation
import HealthKit
import GRDB

/// Incremental sync via HKAnchoredObjectQuery (PRD F-001).
///
/// Per-type loop:
/// 1. Load persisted `HKQueryAnchor` (BLOB, NSKeyedArchiver / SecureCoding) from `sync_anchors`.
///    First run → `nil` anchor → HealthKit returns the full set, but the matching backfill has
///    already inserted those rows, so `INSERT OR IGNORE` makes this idempotent.
/// 2. `anchoredFetch` returns (added, deleted, newAnchor).
/// 3. Map added → `health_samples_raw` (INSERT OR IGNORE on `sample_uuid`).
/// 4. Mark deleted UUIDs as `is_deleted=1` (soft delete; raw is append-only-ish per PRD §6).
/// 5. Persist `newAnchor`. UPSERT keyed on `hk_type`.
/// 6. On HK failure: exponential backoff retry up to 3x; if still failing, record and continue.
///
/// Idempotency: re-running on the same anchor is a no-op (HealthKit returns 0 added / 0 deleted).
final class IncrementalSyncCoordinator {

    private let healthKitManager: HealthKitManager
    private let database: DatabaseManager
    private let maxAttempts: Int

    init(
        healthKitManager: HealthKitManager,
        database: DatabaseManager,
        maxAttempts: Int = 3
    ) {
        self.healthKitManager = healthKitManager
        self.database = database
        self.maxAttempts = maxAttempts
    }

    struct TypeOutcome {
        let identifier: String
        let added: Int
        let deleted: Int
        let attempts: Int
        let error: Error?
    }

    func run(
        trigger: SyncJob.Trigger,
        progress: @escaping (String) -> Void
    ) async throws -> SyncEngine.LastResult {

        let jobStart = Date()
        let jobId = try insertJob(trigger: trigger, startedAt: jobStart)

        var perTypeCounts: [String: Int] = [:]
        var firstError: Error?

        let sampleTypes = HealthKitTypeCatalog.allReadSampleTypes
        let total = sampleTypes.count

        for (index, sampleType) in sampleTypes.enumerated() {
            let identifier = sampleType.identifier
            progress("[\(index + 1)/\(total)] 增量同步 \(identifier)…")

            let outcome = await syncType(sampleType, identifier: identifier)
            perTypeCounts[identifier] = outcome.added

            if let err = outcome.error {
                if firstError == nil { firstError = err }
                AppLogger.shared.sync.error(
                    "Incremental failed for \(identifier, privacy: .public) after \(outcome.attempts) attempts: \(err.localizedDescription, privacy: .public)"
                )
            } else {
                AppLogger.shared.sync.info(
                    "Incremental \(identifier, privacy: .public): +\(outcome.added) / -\(outcome.deleted)"
                )
            }
        }

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
            jobType: .incremental,
            succeeded: succeeded,
            startedAt: jobStart,
            endedAt: endedAt,
            totalSamples: totalSamples,
            perTypeCounts: perTypeCounts,
            errorMessage: firstError?.localizedDescription
        )
    }

    // MARK: - Per-type sync with retry

    private func syncType(
        _ sampleType: HKSampleType,
        identifier: String
    ) async -> TypeOutcome {
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let storedAnchor = try loadAnchor(for: identifier)
                let result = try await healthKitManager.anchoredFetch(
                    for: sampleType,
                    anchor: storedAnchor
                )

                let addedCount = try persistAdded(result.added)
                let deletedCount = try persistDeleted(result.deleted)

                if let newAnchor = result.newAnchor {
                    try saveAnchor(newAnchor, for: identifier)
                }

                return TypeOutcome(
                    identifier: identifier,
                    added: addedCount,
                    deleted: deletedCount,
                    attempts: attempt,
                    error: nil
                )
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    // Exponential backoff: 0.5s, 1.5s (capped well under BG task budget)
                    let delayNs = UInt64(pow(2.0, Double(attempt - 1)) * 0.5 * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }
        }

        return TypeOutcome(
            identifier: identifier,
            added: 0,
            deleted: 0,
            attempts: attempt,
            error: lastError
        )
    }

    // MARK: - Anchor persistence

    private func loadAnchor(for identifier: String) throws -> HKQueryAnchor? {
        let row: SyncAnchor? = try database.read { db in
            try SyncAnchor.fetchOne(db, key: identifier)
        }
        guard let row else { return nil }
        return try NSKeyedUnarchiver.unarchivedObject(
            ofClass: HKQueryAnchor.self,
            from: row.anchorData
        )
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for identifier: String) throws {
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: anchor,
            requiringSecureCoding: true
        )
        let row = SyncAnchor(
            hkType: identifier,
            anchorData: data,
            updatedAt: Int64(Date().timeIntervalSince1970)
        )
        try database.write { db in
            // UPSERT on primary key (hk_type)
            try row.insert(db, onConflict: .replace)
        }
    }

    // MARK: - Sample persistence

    private func persistAdded(_ samples: [HKSample]) throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let ingestedAt = Date()
        let rows = samples.compactMap { SampleMapper.map($0, ingestedAt: ingestedAt) }
        guard !rows.isEmpty else { return 0 }
        try database.write { db in
            for row in rows {
                try row.insert(db, onConflict: .ignore)
            }
        }
        return rows.count
    }

    private func persistDeleted(_ deleted: [HKDeletedObject]) throws -> Int {
        guard !deleted.isEmpty else { return 0 }
        let uuids = deleted.map { $0.uuid.uuidString }
        try database.write { db in
            // Chunk to keep SQL parameter count well under SQLite's default 999 limit.
            for chunk in uuids.chunked(into: 400) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "UPDATE health_samples_raw SET is_deleted = 1 WHERE sample_uuid IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
            }
        }
        return uuids.count
    }

    // MARK: - Job lifecycle

    private func insertJob(trigger: SyncJob.Trigger, startedAt: Date) throws -> Int64 {
        var job = SyncJob(
            id: nil,
            jobType: .incremental,
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
            throw NSError(domain: "IncrementalSyncCoordinator", code: -1)
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
