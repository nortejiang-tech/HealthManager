import Foundation
import GRDB

struct ProjectionRunResult: Equatable, Sendable {
    let processed: Int
    let changedDates: Set<String>
    let hasPending: Bool
}

/// Consumes durable dirty-date generations in bounded batches. A row is acknowledged only
/// when its captured generation is still current, so a change arriving during aggregation
/// remains pending for the next pass.
actor ProjectionWorker {
    private let database: DatabaseManager
    private let aggregator: DailyAggregator
    private let projectionVersion: Int
    private let onCalendarEvidenceScanStarted: (@Sendable () -> Void)?

    init(
        database: DatabaseManager,
        projectionVersion: Int = 1,
        onCalendarEvidenceScanStarted: (@Sendable () -> Void)? = nil
    ) {
        self.database = database
        self.aggregator = DailyAggregator(database: database)
        self.projectionVersion = projectionVersion
        self.onCalendarEvidenceScanStarted = onCalendarEvidenceScanStarted
    }

    func hasPending(calendar: Calendar = .current) throws -> Bool {
        let zone = calendar.timeZone.identifier
        return try database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM sync_projection_work
                        WHERE time_zone = ? AND projection_version = ?
                    )
                    """,
                arguments: [zone, projectionVersion]
            ) ?? false
        }
    }

    func runBatch(
        limit: Int = 32,
        calendar: Calendar = .current,
        afterRebuildBeforeAcknowledge: (() throws -> Void)? = nil
    ) async throws -> ProjectionRunResult {
        guard limit > 0 else {
            return ProjectionRunResult(processed: 0, changedDates: [], hasPending: try hasPending(calendar: calendar))
        }
        try await prepareCalendarIfNeeded(calendar)
        let zone = calendar.timeZone.identifier
        let captured: [SyncProjectionWork] = try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT local_date, time_zone, projection_version, generation
                    FROM sync_projection_work
                    WHERE time_zone = ? AND projection_version = ?
                    ORDER BY local_date
                    LIMIT ?
                    """,
                arguments: [zone, projectionVersion, limit]
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

        var changed: Set<String> = []
        var processed = 0
        for work in captured {
            let dateChanges = try await aggregator.rebuild(
                dates: [work.key.localDate],
                calendar: calendar
            )
            try afterRebuildBeforeAcknowledge?()
            try database.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM sync_projection_work
                        WHERE local_date = ? AND time_zone = ?
                          AND projection_version = ? AND generation = ?
                        """,
                    arguments: [
                        work.key.localDate,
                        work.key.timeZone,
                        work.key.projectionVersion,
                        work.generation
                    ]
                )
            }
            changed.formUnion(dateChanges)
            processed += 1
        }
        return ProjectionRunResult(
            processed: processed,
            changedDates: changed,
            hasPending: try hasPending(calendar: calendar)
        )
    }

    /// A timezone/version change queues only dates backed by raw evidence. Restored aggregate
    /// rows without raw coverage are preserved and never replaced with synthetic zeroes.
    private func prepareCalendarIfNeeded(_ calendar: Calendar) async throws {
        let zone = calendar.timeZone.identifier
        let projectionVersion = self.projectionVersion
        let onCalendarEvidenceScanStarted = self.onCalendarEvidenceScanStarted

        // A mature HealthKit database can contain millions of raw samples. Discovering their
        // local dates used to run inside the single writer transaction, which blocked every
        // interactive write (including meal saves) until the full scan completed. WAL readers
        // provide a stable snapshot without occupying the writer, so only the compact set of
        // discovered dates is published in the short transaction below.
        let dates: Set<String>? = try await database.asyncRead { db in
            let runtime = try Row.fetchOne(
                db,
                sql: "SELECT projection_time_zone, projection_version FROM sync_runtime_state WHERE id = 1"
            )
            let storedZone: String? = runtime?["projection_time_zone"]
            let storedVersion: Int = runtime?["projection_version"] ?? projectionVersion
            guard storedZone != zone || storedVersion != projectionVersion else { return nil }

            onCalendarEvidenceScanStarted?()
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"

            let ranges = try Row.fetchCursor(
                db,
                sql: "SELECT start_at, end_at FROM health_samples_raw WHERE is_deleted = 0"
            )
            var dates: Set<String> = []
            while let row = try ranges.next() {
                let start: Int64 = row["start_at"]
                let end: Int64 = row["end_at"]
                dates.formUnion(Self.localDates(
                    start: start,
                    end: end,
                    calendar: calendar,
                    formatter: formatter
                ))
            }
            return dates
        }

        guard let dates else { return }

        try await database.asyncWrite { db in
            // Another process may have completed the same bootstrap while the read snapshot was
            // scanning. Recheck before publishing so generations are not needlessly advanced.
            let runtime = try Row.fetchOne(
                db,
                sql: "SELECT projection_time_zone, projection_version FROM sync_runtime_state WHERE id = 1"
            )
            let storedZone: String? = runtime?["projection_time_zone"]
            let storedVersion: Int = runtime?["projection_version"] ?? projectionVersion
            guard storedZone != zone || storedVersion != projectionVersion else { return }

            for date in dates {
                try db.execute(
                    sql: """
                        INSERT INTO sync_projection_work
                            (local_date, time_zone, projection_version, generation)
                        VALUES (?, ?, ?, 1)
                        ON CONFLICT(local_date, time_zone, projection_version)
                        DO UPDATE SET generation = generation + 1
                        """,
                    arguments: [date, zone, projectionVersion]
                )
            }
            try db.execute(
                sql: "DELETE FROM sync_projection_work WHERE time_zone != ? OR projection_version != ?",
                arguments: [zone, projectionVersion]
            )
            try db.execute(
                sql: """
                    UPDATE sync_runtime_state
                    SET projection_time_zone = ?, projection_version = ?, updated_at = ?
                    WHERE id = 1
                    """,
                arguments: [zone, projectionVersion, Date().timeIntervalSince1970]
            )
        }
    }

    private static func localDates(
        start: Int64,
        end: Int64,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> Set<String> {
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(start)))
        let inclusiveEnd = max(start, end - 1)
        let last = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(inclusiveEnd)))
        var result: Set<String> = []
        while day <= last {
            result.insert(formatter.string(from: day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        return result
    }
}
