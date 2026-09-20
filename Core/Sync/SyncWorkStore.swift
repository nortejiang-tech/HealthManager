import Foundation
import GRDB

enum SyncDeferredReason: String, Equatable, Sendable {
    case waitForUnlock
    case authorizationCheck
    case cancelled
    case transient
    case repairRequired
    case failure
}

struct SyncTypeWork: Equatable, Sendable {
    let hkType: String
    let requestedGeneration: Int64
    let completedGeneration: Int64
    let reasonMask: Int
    let deferredReason: SyncDeferredReason?
    let retryAt: TimeInterval?
    let lastCheckedAt: TimeInterval?
    let lastErrorCode: String?

    var isPending: Bool { completedGeneration < requestedGeneration }
}

struct SyncProjectionWorkKey: Hashable, Sendable {
    let localDate: String
    let timeZone: String
    let projectionVersion: Int
}

struct SyncProjectionWork: Equatable, Sendable {
    let key: SyncProjectionWorkKey
    let generation: Int64
}

struct SyncRuntimeState: Equatable, Sendable {
    let restoreInProgress: Bool
    let projectionTimeZone: String?
    let projectionVersion: Int
    let runnerPausedReason: String?
    let updatedAt: TimeInterval
}

struct SyncPageCommit {
    let claim: SyncClaim
    let addedRows: [HealthSampleRaw]
    let deletedUUIDs: [String]
    let newAnchorData: Data?
    let drained: Bool
    let calendar: Calendar
    let projectionVersion: Int
    let committedAt: Date

    init(
        claim: SyncClaim,
        addedRows: [HealthSampleRaw],
        deletedUUIDs: [String],
        newAnchorData: Data?,
        drained: Bool,
        calendar: Calendar,
        projectionVersion: Int,
        committedAt: Date = Date()
    ) {
        self.claim = claim
        self.addedRows = addedRows
        self.deletedUUIDs = deletedUUIDs
        self.newAnchorData = newAnchorData
        self.drained = drained
        self.calendar = calendar
        self.projectionVersion = projectionVersion
        self.committedAt = committedAt
    }
}

struct SyncPageCommitResult: Equatable, Sendable {
    let actualInserted: Int
    let actualDeleted: Int
    let unknownTombstones: Int
    let changedProjectionKeys: Set<SyncProjectionWorkKey>
}

enum SyncWorkStoreFailurePoint: Equatable, Sendable {
    case afterInsert
    case afterDelete
    case beforeAnchor
    case afterAnchorBeforeCommit
}

enum SyncWorkStoreError: Error, Equatable {
    case emptyTypes
    case generationOverflow(type: String)
    case invalidClaim
    case mixedSampleType(expected: String, actual: String)
    case injected(SyncWorkStoreFailurePoint)
}

/// Durable runtime ledger for sync demand and projection work.
/// Every page mutation is committed through one DatabasePool write transaction.
struct SyncWorkStore: @unchecked Sendable {
    private let pool: DatabasePool

    init(database: DatabaseManager) {
        self.pool = database.pool
    }

    init(pool: DatabasePool) {
        self.pool = pool
    }

    func request(types: Set<String>, reason: SyncReason) throws {
        guard !types.isEmpty else { throw SyncWorkStoreError.emptyTypes }
        let ordered = types.sorted()

        try pool.write { db in
            for type in ordered {
                let current = try Int64.fetchOne(
                    db,
                    sql: "SELECT requested_generation FROM sync_type_work WHERE hk_type = ?",
                    arguments: [type]
                ) ?? 0
                guard current < Int64.max else {
                    throw SyncWorkStoreError.generationOverflow(type: type)
                }
            }

            for type in ordered {
                try db.execute(
                    sql: """
                        INSERT INTO sync_type_work
                            (hk_type, requested_generation, completed_generation, reason_mask)
                        VALUES (?, 1, 0, ?)
                        ON CONFLICT(hk_type) DO UPDATE SET
                            requested_generation = requested_generation + 1,
                            reason_mask = reason_mask | excluded.reason_mask
                        """,
                    arguments: [type, reason.bitMask]
                )
            }
        }
    }

    func work(for type: String) throws -> SyncTypeWork? {
        try pool.read { db in
            try fetchWork(db, type: type)
        }
    }

    func pendingWork(now: Date = Date()) throws -> [SyncTypeWork] {
        try pool.read { db in
            let runtime = try Row.fetchOne(
                db,
                sql: "SELECT restore_in_progress, runner_paused_reason FROM sync_runtime_state WHERE id = 1"
            )
            let restoreInProgress: Bool = runtime?["restore_in_progress"] ?? false
            let pausedReason: String? = runtime?["runner_paused_reason"]
            guard !restoreInProgress, pausedReason == nil else { return [] }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM sync_type_work
                    WHERE completed_generation < requested_generation
                      AND (
                        deferred_reason IS NULL
                        OR (deferred_reason = ? AND (retry_at IS NULL OR retry_at <= ?))
                      )
                    ORDER BY hk_type
                    """,
                arguments: [SyncDeferredReason.transient.rawValue, now.timeIntervalSince1970]
            )
            return rows.map(Self.decodeWork)
        }
    }

    func claim(type: String, token: UUID, now: Date = Date()) throws -> SyncClaim? {
        try pool.read { db in
            let runtime = try Row.fetchOne(
                db,
                sql: "SELECT restore_in_progress, runner_paused_reason FROM sync_runtime_state WHERE id = 1"
            )
            let restoreInProgress: Bool = runtime?["restore_in_progress"] ?? false
            let pausedReason: String? = runtime?["runner_paused_reason"]
            guard !restoreInProgress, pausedReason == nil,
                  let work = try fetchWork(db, type: type), work.isPending else { return nil }
            if let deferred = work.deferredReason {
                guard deferred == .transient,
                      work.retryAt.map({ $0 <= now.timeIntervalSince1970 }) ?? true else {
                    return nil
                }
            }
            return SyncClaim(
                token: token,
                capturedGeneration: [type: work.requestedGeneration]
            )
        }
    }

    func deferClaim(
        _ claim: SyncClaim,
        reason: SyncDeferredReason,
        retryAt: Date? = nil,
        errorCode: String? = nil,
        checkedAt: Date = Date()
    ) throws {
        let (type, generation) = try Self.singleType(from: claim)
        try pool.write { db in
            guard let work = try fetchWork(db, type: type),
                  generation <= work.requestedGeneration else {
                throw SyncWorkStoreError.invalidClaim
            }
            try db.execute(
                sql: """
                    UPDATE sync_type_work
                    SET deferred_reason = ?, retry_at = ?, last_checked_at = ?, last_error_code = ?
                    WHERE hk_type = ?
                    """,
                arguments: [
                    reason.rawValue,
                    retryAt?.timeIntervalSince1970,
                    checkedAt.timeIntervalSince1970,
                    errorCode,
                    type
                ]
            )
        }
    }

    func resume(types: Set<String>, reason: SyncDeferredReason? = nil) throws {
        guard !types.isEmpty else { return }
        try pool.write { db in
            for type in types {
                if let reason {
                    try db.execute(
                        sql: """
                            UPDATE sync_type_work
                            SET deferred_reason = NULL, retry_at = NULL, last_error_code = NULL
                            WHERE hk_type = ? AND deferred_reason = ?
                            """,
                        arguments: [type, reason.rawValue]
                    )
                } else {
                    try db.execute(
                        sql: """
                            UPDATE sync_type_work
                            SET deferred_reason = NULL, retry_at = NULL, last_error_code = NULL
                            WHERE hk_type = ?
                            """,
                        arguments: [type]
                    )
                }
            }
        }
    }

    func commitPage(
        _ page: SyncPageCommit,
        injecting failurePoint: SyncWorkStoreFailurePoint? = nil
    ) throws -> SyncPageCommitResult {
        let (type, capturedGeneration) = try Self.singleType(from: page.claim)
        guard page.projectionVersion > 0 else { throw SyncWorkStoreError.invalidClaim }
        for row in page.addedRows where row.hkType != type {
            throw SyncWorkStoreError.mixedSampleType(expected: type, actual: row.hkType)
        }

        return try pool.write { db in
            guard let work = try fetchWork(db, type: type),
                  capturedGeneration > 0,
                  capturedGeneration <= work.requestedGeneration else {
                throw SyncWorkStoreError.invalidClaim
            }

            var inserted = 0
            var deleted = 0
            var unknownTombstones = 0
            var changedKeys: Set<SyncProjectionWorkKey> = []

            for row in page.addedRows {
                try row.insert(db, onConflict: .ignore)
                if db.changesCount > 0 {
                    inserted += db.changesCount
                    changedKeys.formUnion(Self.projectionKeys(
                        startAt: row.startAt,
                        endAt: row.endAt,
                        calendar: page.calendar,
                        version: page.projectionVersion
                    ))
                }
            }
            try Self.inject(.afterInsert, requested: failurePoint)

            for uuid in Set(page.deletedUUIDs) {
                let existing = try HealthSampleRaw.fetchOne(db, key: uuid)
                guard let existing else {
                    unknownTombstones += 1
                    continue
                }
                guard !existing.isDeleted else { continue }

                try db.execute(
                    sql: "UPDATE health_samples_raw SET is_deleted = 1 WHERE sample_uuid = ? AND is_deleted = 0",
                    arguments: [uuid]
                )
                if db.changesCount > 0 {
                    deleted += db.changesCount
                    changedKeys.formUnion(Self.projectionKeys(
                        startAt: existing.startAt,
                        endAt: existing.endAt,
                        calendar: page.calendar,
                        version: page.projectionVersion
                    ))
                }
            }
            try Self.inject(.afterDelete, requested: failurePoint)

            for key in changedKeys {
                try db.execute(
                    sql: """
                        INSERT INTO sync_projection_work
                            (local_date, time_zone, projection_version, generation)
                        VALUES (?, ?, ?, 1)
                        ON CONFLICT(local_date, time_zone, projection_version)
                        DO UPDATE SET generation = generation + 1
                        """,
                    arguments: [key.localDate, key.timeZone, key.projectionVersion]
                )
            }

            try Self.inject(.beforeAnchor, requested: failurePoint)
            if let anchorData = page.newAnchorData {
                try db.execute(
                    sql: """
                        INSERT INTO sync_anchors (hk_type, anchor_data, updated_at)
                        VALUES (?, ?, ?)
                        ON CONFLICT(hk_type) DO UPDATE SET
                            anchor_data = excluded.anchor_data,
                            updated_at = excluded.updated_at
                        """,
                    arguments: [type, anchorData, Int64(page.committedAt.timeIntervalSince1970)]
                )
            }

            if page.drained {
                try db.execute(
                    sql: """
                        UPDATE sync_type_work
                        SET completed_generation = MAX(completed_generation, ?),
                            reason_mask = CASE WHEN requested_generation <= ? THEN 0 ELSE reason_mask END,
                            deferred_reason = NULL,
                            retry_at = NULL,
                            last_checked_at = ?,
                            last_error_code = NULL
                        WHERE hk_type = ?
                        """,
                    arguments: [
                        capturedGeneration,
                        capturedGeneration,
                        page.committedAt.timeIntervalSince1970,
                        type
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        UPDATE sync_type_work
                        SET deferred_reason = NULL, retry_at = NULL,
                            last_checked_at = ?, last_error_code = NULL
                        WHERE hk_type = ?
                        """,
                    arguments: [page.committedAt.timeIntervalSince1970, type]
                )
            }

            try Self.inject(.afterAnchorBeforeCommit, requested: failurePoint)
            return SyncPageCommitResult(
                actualInserted: inserted,
                actualDeleted: deleted,
                unknownTombstones: unknownTombstones,
                changedProjectionKeys: changedKeys
            )
        }
    }

    func projectionWork() throws -> [SyncProjectionWork] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT local_date, time_zone, projection_version, generation
                    FROM sync_projection_work
                    ORDER BY local_date, time_zone, projection_version
                    """
            ).map { row in
                SyncProjectionWork(
                    key: SyncProjectionWorkKey(
                        localDate: row["local_date"],
                        timeZone: row["time_zone"],
                        projectionVersion: row["projection_version"]
                    ),
                    generation: row["generation"]
                )
            }
        }
    }

    func runtimeState() throws -> SyncRuntimeState {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_runtime_state WHERE id = 1") else {
                throw SyncWorkStoreError.invalidClaim
            }
            return SyncRuntimeState(
                restoreInProgress: row["restore_in_progress"],
                projectionTimeZone: row["projection_time_zone"],
                projectionVersion: row["projection_version"],
                runnerPausedReason: row["runner_paused_reason"],
                updatedAt: row["updated_at"]
            )
        }
    }

    func setRestoreInProgress(
        _ inProgress: Bool,
        pausedReason: String? = nil,
        at date: Date = Date()
    ) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                    UPDATE sync_runtime_state
                    SET restore_in_progress = ?, runner_paused_reason = ?, updated_at = ?
                    WHERE id = 1
                    """,
                arguments: [inProgress, pausedReason, date.timeIntervalSince1970]
            )
        }
    }

    private func fetchWork(_ db: Database, type: String) throws -> SyncTypeWork? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM sync_type_work WHERE hk_type = ?",
            arguments: [type]
        ) else { return nil }
        return Self.decodeWork(row)
    }

    private static func decodeWork(_ row: Row) -> SyncTypeWork {
        let deferred: String? = row["deferred_reason"]
        return SyncTypeWork(
            hkType: row["hk_type"],
            requestedGeneration: row["requested_generation"],
            completedGeneration: row["completed_generation"],
            reasonMask: row["reason_mask"],
            deferredReason: deferred.flatMap(SyncDeferredReason.init(rawValue:)),
            retryAt: row["retry_at"],
            lastCheckedAt: row["last_checked_at"],
            lastErrorCode: row["last_error_code"]
        )
    }

    private static func singleType(from claim: SyncClaim) throws -> (String, Int64) {
        guard claim.capturedGeneration.count == 1,
              let entry = claim.capturedGeneration.first else {
            throw SyncWorkStoreError.invalidClaim
        }
        return (entry.key, entry.value)
    }

    private static func inject(
        _ point: SyncWorkStoreFailurePoint,
        requested: SyncWorkStoreFailurePoint?
    ) throws {
        if point == requested {
            throw SyncWorkStoreError.injected(point)
        }
    }

    private static func projectionKeys(
        startAt: Int64,
        endAt: Int64,
        calendar: Calendar,
        version: Int
    ) -> Set<SyncProjectionWorkKey> {
        let calendar = calendar
        let timeZone = calendar.timeZone.identifier
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let start = Date(timeIntervalSince1970: TimeInterval(startAt))
        let inclusiveEndEpoch = max(startAt, endAt - 1)
        let end = Date(timeIntervalSince1970: TimeInterval(inclusiveEndEpoch))
        var day = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        var keys: Set<SyncProjectionWorkKey> = []

        while day <= lastDay {
            keys.insert(SyncProjectionWorkKey(
                localDate: formatter.string(from: day),
                timeZone: timeZone,
                projectionVersion: version
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                break
            }
            day = next
        }
        return keys
    }
}
