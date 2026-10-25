import Foundation
import GRDB

struct WorkoutChoiceContext: Identifiable, Sendable {
    var id: String { event.contributors.map(\.id).sorted().first ?? event.selected.id }
    let event: WorkoutEvent
    var selectedID: String? { event.choice?.selectedID }
    var label: String {
        if event.isManuallySelected { return "手动 · \(event.selected.sourceName)" }
        if event.choice?.selectedID != nil { return "所选记录已不可用 · 自动补位" }
        return "自动 · \(event.selected.sourceName)"
    }
}

enum WorkoutChoiceError: Error, LocalizedError {
    case changed
    var errorDescription: String? { "运动记录已变化，请重新加载后选择。" }
}

/// User decisions remain separate from immutable HealthKit evidence and survive re-imports.
enum WorkoutChoiceStore {
    static func revision(db: Database) throws -> Double {
        try Double.fetchOne(db, sql: "SELECT COALESCE(MAX(updated_at),0) FROM workout_record_choices WHERE updated_at BETWEEN 0 AND 253402300799") ?? 0
    }

    static func load(db: Database) throws -> [WorkoutRecordChoice] {
        try Row.fetchAll(db, sql: "SELECT * FROM workout_record_choices").compactMap { row in
            guard let data = (row["member_ids_json"] as String?)?.data(using: .utf8),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return WorkoutRecordChoice(id: row["id"], selectedID: row["selected_id"], memberIDs: ids, updatedAt: row["updated_at"])
        }
    }

    static func context(db: Database, recordID: String) throws -> WorkoutChoiceContext {
        guard let anchor = try HealthSampleRaw.fetchOne(db, key: recordID), anchor.hkType == TrainingTypes.workout else { throw WorkoutChoiceError.changed }
        let raw = try HealthSampleRaw.fetchAll(db, sql: """
            SELECT * FROM health_samples_raw WHERE hk_type=? AND is_deleted=0
            AND start_at BETWEEN ? AND ? ORDER BY start_at,sample_uuid
            """, arguments: [TrainingTypes.workout, anchor.startAt - 600, anchor.endAt + 600])
        let events = WorkoutEventResolver.events(raw.compactMap(TrainingSnapshotLoader.sample), choices: try load(db: db))
        guard let event = events.first(where: {
            $0.contributors.contains { $0.id == recordID } || $0.choice?.memberIDs.contains(recordID) == true
        }) else { throw WorkoutChoiceError.changed }
        return WorkoutChoiceContext(event: event)
    }

    /// Persist the choice and durable dirty dates together. A failed projection remains retryable.
    static func save(database: DatabaseManager, recordID: String, selectedID: String?,
                     now: Date = Date(), calendar: Calendar = .current) async throws -> Set<String> {
        try await database.asyncWrite { db in
            let context = try context(db: db, recordID: recordID)
            if let selectedID, !context.event.contributors.contains(where: { $0.id == selectedID }) { throw WorkoutChoiceError.changed }
            let existing = context.event.choice
            let ids = Set(context.event.contributors.map(\.id) + (existing?.memberIDs ?? [])).sorted()
            let encoded = String(decoding: try JSONEncoder().encode(ids), as: UTF8.self)
            // An explicit automatic row acts as a tombstone against older restored choices.
            let previous = try revision(db: db)
            let timestamp = max(now.timeIntervalSince1970, previous + 0.000001)
            guard timestamp.isFinite, timestamp >= 0, timestamp < 253402300799 else { throw WorkoutChoiceError.changed }
            try db.execute(sql: """
                INSERT INTO workout_record_choices(id,selected_id,member_ids_json,updated_at) VALUES(?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET selected_id=excluded.selected_id,
                  member_ids_json=excluded.member_ids_json,updated_at=excluded.updated_at
                """, arguments: [existing?.id ?? UUID().uuidString, selectedID, encoded, timestamp])
            let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
            var dates = Set<String>()
            for sample in context.event.contributors {
                for offset in -1...1 {
                    if let day = calendar.date(byAdding: .day, value: offset, to: sample.start) { dates.insert(formatter.string(from: day)) }
                }
            }
            for date in dates {
                try db.execute(sql: """
                    INSERT INTO sync_projection_work(local_date,time_zone,projection_version,generation) VALUES(?,?,1,1)
                    ON CONFLICT(local_date,time_zone,projection_version) DO UPDATE SET generation=generation+1
                    """, arguments: [date,calendar.timeZone.identifier])
            }
            try invalidateReports(db: db, dates: dates, now: timestamp, calendar: calendar, formatter: formatter)
            return dates
        }
    }

    private static func invalidateReports(db: Database, dates: Set<String>, now: Double, calendar: Calendar, formatter: DateFormatter) throws {
        var weeks = Set<String>()
        for date in dates {
            if let day = formatter.date(from: date) {
                // SummaryGenerator's week starts Monday, independently of the user's locale.
                let weekday = calendar.component(.weekday, from: day)
                if let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) { weeks.insert(formatter.string(from: monday)) }
            }
        }
        for (kind,table,key,jsonKey,keys) in [
            ("daily", "daily_summaries", "date", "key_findings_json", dates),
            ("weekly", "weekly_summaries", "week_start_date", "findings_json", weeks)
        ] {
            for keyValue in keys {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE \(key)=?", arguments: [keyValue]) else { continue }
                let original: Data = kind == "daily" ? try JSONEncoder().encode(DailySummary(row: row)) : try JSONEncoder().encode(WeeklySummary(row: row))
                try db.execute(sql: "INSERT OR IGNORE INTO summary_contract_archive VALUES(?,?,?,?)",
                    arguments: [kind + "_workout_choice", keyValue + ":" + String(now), String(decoding: original, as: UTF8.self), Int64(now)])
                var findings: [String:Any] = [:]
                if let raw: String = row[jsonKey], let data = raw.data(using: .utf8) { findings = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] ?? [:] }
                findings["workoutSelectionPending"] = true
                let json = String(decoding: try JSONSerialization.data(withJSONObject: findings, options: [.sortedKeys]), as: UTF8.self)
                try db.execute(sql: "UPDATE \(table) SET \(jsonKey)=?,llm_text=NULL,llm_model=NULL,llm_generated_at=NULL WHERE \(key)=?", arguments: [json,keyValue])
            }
        }
    }

    static func apply(database: DatabaseManager, recordID: String, selectedID: String?) async throws {
        let dates = try await save(database: database, recordID: recordID, selectedID: selectedID)
        let worker = ProjectionWorker(database: database)
        while try await worker.runBatch(onlyDates: dates).hasPending { try Task.checkCancellation() }
        // Only regenerate reports already present; passive selection does not create new reports.
        let generator = SummaryGenerator(database: database)
        try await generator.refreshPendingWorkoutReports()
    }

    /// Restoring older derived rows must not override a newer local user decision.
    /// Reconcile only groups with original evidence present; never invent absent raw records.
    static func reconcileAfterRestore(database: DatabaseManager, calendar: Calendar = .current) async throws {
        let dates: Set<String> = try await database.asyncRead { db in
            let ids = Set(try load(db: db).flatMap(\.memberIDs))
            guard !ids.isEmpty else { return [] }
            let f = DateFormatter();f.calendar=calendar;f.timeZone=calendar.timeZone;f.dateFormat="yyyy-MM-dd";f.locale=Locale(identifier:"en_US_POSIX")
            var dates=Set<String>()
            for row in try Row.fetchAll(db,sql:"SELECT sample_uuid,start_at FROM health_samples_raw WHERE hk_type=? AND is_deleted=0",arguments:[TrainingTypes.workout]) {
                guard ids.contains(row["sample_uuid"] as String) else { continue }
                let day=Date(timeIntervalSince1970:row["start_at"] as Double)
                for offset in -1...1 {
                    if let date=calendar.date(byAdding:.day,value:offset,to:day) {dates.insert(f.string(from:date))}
                }
            }
            return dates
        }
        guard !dates.isEmpty else { return }
        try await database.asyncWrite { db in
            for date in dates {
                try db.execute(sql:"INSERT INTO sync_projection_work(local_date,time_zone,projection_version,generation) VALUES(?,?,1,1) ON CONFLICT(local_date,time_zone,projection_version) DO UPDATE SET generation=generation+1",arguments:[date,calendar.timeZone.identifier])
            }
            let f=DateFormatter();f.calendar=calendar;f.timeZone=calendar.timeZone;f.dateFormat="yyyy-MM-dd";f.locale=Locale(identifier:"en_US_POSIX")
            try invalidateReports(db:db,dates:dates,now:Date().timeIntervalSince1970,calendar:calendar,formatter:f)
        }
        _ = try await DailyAggregator(database:database).rebuild(dates:dates,calendar:calendar)
        try await SummaryGenerator(database:database).refreshPendingWorkoutReports()
    }
}
