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
actor IncrementalSyncCoordinator {

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
        let failedStage: SyncStage?
    }

    /// Result of one full pass over every read sample type. Job-row agnostic.
    /// `ManualSyncCoordinator` invokes `executePass` twice under a single `manual` job row.
    struct PassResult {
        var perTypeCounts: [String: Int]
        /// `firstError` is the first **non-authorization** failure. Auth-denied per-type
        /// failures are recorded in `errors` but do not poison the overall job status.
        var firstError: Error?
        var errors: [SyncTypeError]
    }

    func run(
        trigger: SyncJob.Trigger,
        progress: @escaping (String) -> Void
    ) async throws -> SyncEngine.LastResult {

        let jobStart = Date()
        let jobId = try SyncJobRecorder(database: database).openJob(jobType: .incremental, trigger: trigger, startedAt: jobStart)

        let pass = await executePass(progress: progress)

        let endedAt = Date()
        let totalSamples = pass.perTypeCounts.values.reduce(0, +)
        let succeeded = (pass.firstError == nil)
        try SyncJobRecorder(database: database).closeJob(
            id: jobId,
            endedAt: endedAt,
            succeeded: succeeded,
            errorMessage: pass.firstError?.localizedDescription,
            stats: pass.perTypeCounts
        )

        return SyncEngine.LastResult(
            jobId: jobId,
            jobType: .incremental,
            succeeded: succeeded,
            startedAt: jobStart,
            endedAt: endedAt,
            totalSamples: totalSamples,
            perTypeCounts: pass.perTypeCounts,
            perTypeErrors: pass.errors,
            errorMessage: pass.firstError?.localizedDescription
        )
    }

    /// Iterate every read sample type once: load anchor → anchored fetch → persist → save anchor.
    /// Returns aggregated counts so callers can manage their own sync_jobs envelope.
    func executePass(progress: @escaping (String) -> Void) async -> PassResult {
        var perTypeCounts: [String: Int] = [:]
        var firstError: Error?
        var errors: [SyncTypeError] = []

        let sampleTypes = HealthKitTypeCatalog.allReadSampleTypes
        let total = sampleTypes.count

        for (index, sampleType) in sampleTypes.enumerated() {
            let identifier = sampleType.identifier
            progress("[\(index + 1)/\(total)] 增量同步 \(identifier)…")

            let outcome = await syncType(sampleType, identifier: identifier)
            perTypeCounts[identifier] = outcome.added

            if let err = outcome.error {
                let authDenied = SyncTypeError.isAuthorizationDenied(err)
                errors.append(SyncTypeError(
                    hkType: identifier,
                    stage: outcome.failedStage ?? .hkQuery,
                    underlying: err.localizedDescription,
                    isAuthDenied: authDenied,
                    occurredAt: Date()
                ))
                // Auth denial is expected when the user only granted a subset of types.
                // Don't promote it into firstError — the overall job can still be a success.
                if !authDenied, firstError == nil {
                    firstError = err
                }
                if authDenied {
                    AppLogger.shared.sync.info(
                        "Incremental \(identifier, privacy: .public): authorization denied (soft skip)"
                    )
                } else {
                    AppLogger.shared.sync.error(
                        "Incremental failed for \(identifier, privacy: .public) at stage \(outcome.failedStage?.rawValue ?? "?") after \(outcome.attempts) attempts: \(err.localizedDescription, privacy: .public)"
                    )
                }
            } else {
                AppLogger.shared.sync.info(
                    "Incremental \(identifier, privacy: .public): +\(outcome.added) / -\(outcome.deleted)"
                )
            }
        }

        return PassResult(
            perTypeCounts: perTypeCounts,
            firstError: firstError,
            errors: errors
        )
    }

    // MARK: - Per-type sync with retry

    private func syncType(
        _ sampleType: HKSampleType,
        identifier: String
    ) async -> TypeOutcome {
        var attempt = 0
        var lastError: Error?
        var lastStage: SyncStage?

        while attempt < maxAttempts {
            attempt += 1
            var currentStage: SyncStage = .loadAnchor
            do {
                let storedAnchor = try loadAnchor(for: identifier)

                currentStage = .hkQuery
                let result = try await healthKitManager.anchoredFetch(
                    for: sampleType,
                    anchor: storedAnchor
                )

                currentStage = .persistDB
                let addedCount = try persistAdded(result.added)
                let deletedCount = try persistDeleted(result.deleted)

                if let newAnchor = result.newAnchor {
                    currentStage = .saveAnchor
                    try saveAnchor(newAnchor, for: identifier)
                }

                return TypeOutcome(
                    identifier: identifier,
                    added: addedCount,
                    deleted: deletedCount,
                    attempts: attempt,
                    error: nil,
                    failedStage: nil
                )
            } catch {
                lastError = error
                lastStage = currentStage
                // Authorization denial won't succeed on retry — abort retries early.
                if SyncTypeError.isAuthorizationDenied(error) { break }
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
            error: lastError,
            failedStage: lastStage
        )
    }

    // MARK: - Anchor persistence

    private func loadAnchor(for identifier: String) throws -> HKQueryAnchor? {
        let row: SyncAnchor? = try database.read { db in
            try SyncAnchor.fetchOne(db, key: identifier)
        }
        guard let row else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: row.anchorData
            )
        } catch {
            // Stored anchor blob is corrupt or written by an incompatible SDK version.
            // Drop the row and re-fetch the full set; INSERT OR IGNORE on sample_uuid dedupes.
            AppLogger.shared.sync.warning(
                "Anchor decode failed for \(identifier, privacy: .public); resetting. Underlying: \(error.localizedDescription, privacy: .public)"
            )
            try? database.write { db in
                try db.execute(
                    sql: "DELETE FROM sync_anchors WHERE hk_type = ?",
                    arguments: [identifier]
                )
            }
            return nil
        }
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
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
