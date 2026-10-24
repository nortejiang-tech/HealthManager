import Foundation
import GRDB

enum WorkoutEventProjection {
    static func events(db: Database, start: Int64, end: Int64) throws -> [WorkoutEvent] {
        let raw = try HealthSampleRaw.fetchAll(db, sql: "SELECT * FROM health_samples_raw WHERE hk_type=? AND is_deleted=0 AND start_at BETWEEN ? AND ? ORDER BY sample_uuid", arguments: [TrainingTypes.workout, start - 600, end + 600])
        return WorkoutEventResolver.events(raw.compactMap(TrainingSnapshotLoader.sample)).filter {
            $0.selected.start.timeIntervalSince1970 >= Double(start) && $0.selected.start.timeIntervalSince1970 <= Double(end)
        }
    }
    static func rebuild(db: Database, date: String, start: Int64, end: Int64) throws {
        guard date >= DailySourceProjection.effectiveDate else { return }
        let events = try events(db: db, start: start, end: end)
        var activeIDs = Set<String>()
        for event in events {
            let s = event.selected
            activeIDs.insert(s.id)
            let extra: [String:Any] = ["activityType":s.activityType as Any? ?? NSNull(),"duration":s.duration as Any? ?? NSNull(),"totalDistanceMeters":s.distance as Any? ?? NSNull(),"totalEnergyKcal":s.energyKcal as Any? ?? NSNull()]
            let extraJSON = String(decoding:try JSONSerialization.data(withJSONObject:extra,options:[.sortedKeys]),as:UTF8.self)
            let object: [String: Any] = ["sample_uuid":s.id,"event_id":s.id,"hk_type":TrainingTypes.workout,"date":date,
                "start_at":s.start.timeIntervalSince1970,"end_at":s.end.timeIntervalSince1970,
                "source_bundle_id":s.source,"source_name":s.sourceName,"source_origin":s.origin,
                "activityType":s.activityType as Any? ?? NSNull(),"duration":s.duration as Any? ?? NSNull(),
                "totalDistanceMeters":s.distance as Any? ?? NSNull(),"totalEnergyKcal":s.energyKcal as Any? ?? NSNull(),
                "source_policy":WorkoutEventResolver.policyVersion,"value":s.duration ?? 0,"unit":"second","kind":"workout","is_deleted":false,"extra_json":extraJSON,
                "contributor_ids":event.contributors.map(\.id).sorted(),"selection_notes":event.notes]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO workout_events(id,date,payload_json) VALUES(?,?,?)
                ON CONFLICT(id) DO UPDATE SET date=excluded.date,payload_json=excluded.payload_json
                WHERE workout_events.payload_json IS NOT excluded.payload_json
                """, arguments: [s.id,date,json])
        }
        let existing = try String.fetchAll(db, sql: "SELECT id FROM workout_events WHERE date=?", arguments: [date])
        for id in existing where !activeIDs.contains(id) { try db.execute(sql: "DELETE FROM workout_events WHERE id=?", arguments: [id]) }
    }
}
