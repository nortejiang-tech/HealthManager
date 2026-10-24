import Foundation
import GRDB

/// One projection shared by dashboard rollups, reports and the exported Mac rows.
enum WeightProjection {
    struct Evidence: Codable {
        let weightPolicyVersion: String
        let weight: WeightDayProjection
    }
    static func day(_ key: String, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }
    static func load(db: Database, date: String, calendar: Calendar = .current) throws -> WeightDayProjection {
        guard let day = day(date, calendar: calendar) else { throw CocoaError(.coderInvalidValue) }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let rows = try Row.fetchAll(db, sql: """
            SELECT sample_uuid,start_at,value,source_bundle_id,source_name,source_origin
            FROM health_samples_raw WHERE is_deleted=0 AND hk_type='HKQuantityTypeIdentifierBodyMass'
              AND unit='kg' AND start_at < ? ORDER BY start_at,sample_uuid
            """, arguments: [end.timeIntervalSince1970 + 1800])
        let observations = rows.map { r -> WeightObservation in
            let bundle: String = r["source_bundle_id"] ?? ""
            let name: String = r["source_name"] ?? ""
            let stored: String = r["source_origin"] ?? ""
            let origin = stored.isEmpty ? SourceAttribution.classify(bundleId: bundle, sourceName: name).rawValue : stored
            // Keep both identifiers: an origin incorrectly marked Mijia cannot conceal Garmin.
            return WeightObservation(id: r["sample_uuid"], date: Date(timeIntervalSince1970: r["start_at"]),
                kilograms: r["value"], source: bundle + "|" + name, origin: origin)
        }
        return WeightAggregationPolicy.project(observations: observations, day: day, calendar: calendar)
    }
    static func json(_ projection: WeightDayProjection) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(Evidence(weightPolicyVersion: WeightAggregationPolicy.version, weight: projection)), as: UTF8.self)
    }
    static func decode(_ json: String?) -> WeightDayProjection? {
        guard let data = json?.data(using: .utf8), let e = try? JSONDecoder().decode(Evidence.self, from: data),
              e.weightPolicyVersion == WeightAggregationPolicy.version else { return nil }
        return e.weight
    }
    static func caption(_ p: WeightDayProjection?) -> String {
        guard let p else { return "体重口径更新中" }
        guard p.mean != nil else { return "无体重秤记录 · 佳明体重已排除" }
        let labels = ["凌晨", "上午", "下午", "晚间"]
        return p.strata.count == 1 ? "仅\(labels[p.strata[0].slot]) · 分时均值" : "分时均值 · \(p.strata.count)/4 时段"
    }
}
