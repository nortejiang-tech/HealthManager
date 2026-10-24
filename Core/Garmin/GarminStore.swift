import Foundation
import GRDB

enum GarminStore {
    /// Upserts by region/metric/day. Empty/error attempts preserve previously valid data and its measurement/fetch time.
    static func save(db: Database, metric: GarminMetric, date: String, payload: GarminMetricPayload?,
                     attemptedAt: Date, errorCategory: String? = nil) throws {
        let id = "cn|\(metric.rawValue)|\(date)"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = try payload.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let state = errorCategory != nil ? "error" : (payload == nil ? "noData" : "available")
        let previous = try Row.fetchOne(db,sql:"SELECT payload_json,state FROM garmin_daily_metrics WHERE id=?",arguments:[id])
        let oldPayload: String? = previous?["payload_json"]
        let oldState: String? = previous?["state"]
        try db.execute(sql: """
            INSERT INTO garmin_daily_metrics
              (id,date,metric,region,payload_json,observed_at,fetched_at,last_attempt_at,state,error_category)
            VALUES (?,?,?,'cn',?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              payload_json=COALESCE(excluded.payload_json,garmin_daily_metrics.payload_json),
              observed_at=CASE WHEN excluded.payload_json IS NOT NULL THEN excluded.observed_at ELSE garmin_daily_metrics.observed_at END,
              fetched_at=COALESCE(excluded.fetched_at,garmin_daily_metrics.fetched_at),
              last_attempt_at=excluded.last_attempt_at,state=excluded.state,error_category=excluded.error_category
            """, arguments: [id, date, metric.rawValue, json, payload?.observedAt,
                payload == nil ? nil : attemptedAt.timeIntervalSince1970, attemptedAt.timeIntervalSince1970, state, errorCategory])
        if metric == .sleep, let seconds = payload?.values["sleepTimeSeconds"], seconds > 0 && seconds <= 86400 {
            // Update only the authoritative sleep projection. A vendor-only refresh must
            // not wipe restored body/energy projections when HealthKit raw is unavailable.
            try db.execute(sql:"""
                INSERT INTO activity_metrics_daily(date,sleep_seconds,sources_json,computed_at)
                VALUES (?,?,json_object('sleepSource','garmin_cn_personal'),?)
                ON CONFLICT(date) DO UPDATE SET sleep_seconds=excluded.sleep_seconds,
                  sources_json=json_set(CASE WHEN json_valid(activity_metrics_daily.sources_json) THEN activity_metrics_daily.sources_json ELSE '{}' END,'$.sleepSource','garmin_cn_personal'),
                  computed_at=excluded.computed_at
                """,arguments:[date,Int64(seconds),Int64(attemptedAt.timeIntervalSince1970)])
        }
        if oldPayload != (json ?? oldPayload) || oldState != state {
            try db.execute(sql:"""
                UPDATE daily_summaries SET key_findings_json=json_remove(key_findings_json,'$.sourcePolicyVersion')
                WHERE date=? AND json_valid(key_findings_json)
                """,arguments:[date])
        }
    }
    static func sleepSeconds(db: Database, date: String) throws -> Double? {
        guard let json = try String.fetchOne(db,sql:"SELECT payload_json FROM garmin_daily_metrics WHERE date=? AND metric='sleep' AND region='cn'",arguments:[date]),
              let data = json.data(using:.utf8), let payload = try? JSONDecoder().decode(GarminMetricPayload.self,from:data),
              let seconds = payload.values["sleepTimeSeconds"], seconds.isFinite && seconds > 0 && seconds <= 86400 else { return nil }
        return seconds
    }
    static func records(db: Database, since: String) throws -> [GarminMetricRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM garmin_daily_metrics WHERE date>=? ORDER BY date DESC,metric", arguments: [since]).compactMap { row in
            guard let metric = GarminMetric(rawValue: row["metric"]) else { return nil }
            let json: String? = row["payload_json"]
            let payload = json.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(GarminMetricPayload.self, from: $0) }
            let fetched: Double? = row["fetched_at"]
            return GarminMetricRecord(id: row["id"], date: row["date"], metric: metric, payload: payload,
                fetchedAt: fetched.map(Date.init(timeIntervalSince1970:)),
                lastAttemptAt: Date(timeIntervalSince1970: row["last_attempt_at"]), state: row["state"])
        }
    }
}
