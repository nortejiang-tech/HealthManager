import Foundation
import GRDB

enum TrainingParameterLoader {
    static func load(_ db: Database, now: Date, calendar: Calendar) throws -> [String: [TrainingMetricValue]] {
        let begin = calendar.date(byAdding: .day, value: -55, to: calendar.startOfDay(for: now))!
        let firstKey = TrainingCalculator.dayKey(begin, calendar), lastKey = TrainingCalculator.dayKey(now, calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var result: [String: [TrainingMetricValue]] = [:]
        for metric in TrainingMetric.allCases {
            if let daily = metric.daily {
                // Column/table names come only from the closed metric catalog.
                let rows = try Row.fetchAll(db, sql: "SELECT date, \(daily.column) AS value FROM \(daily.table) WHERE date >= ? AND date <= ? AND \(daily.column) IS NOT NULL \(metric == .weight ? "AND json_valid(sources_json) AND json_extract(sources_json,'$.weightPolicyVersion')='weight-time-strata-v1'" : "") ORDER BY date", arguments: [firstKey, lastKey])
                result[metric.id] = rows.compactMap { row in
                    guard let key: String = row["date"], let date = formatter.date(from: key),
                          let value: Double = row["value"], value.isFinite, value >= 0 else { return nil }
                    let converted = value * daily.multiplier
                    guard converted.isFinite else { return nil }
                    return TrainingMetricValue(id: key, date: date, value: converted,
                        source: "daily", sourceName: metric == .weight ? "可信秤 · 分时均值" : "本机日汇总（可能含多来源）")
                }
            } else if let type = metric.rawType {
                let rows = try HealthSampleRaw.fetchAll(db, sql: """
                    SELECT * FROM health_samples_raw WHERE hk_type = ? AND is_deleted = 0
                    AND start_at >= ? AND end_at <= ? AND ingested_at <= ? ORDER BY start_at, sample_uuid
                    """, arguments: [type.rawValue, begin.timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970])
                let expectedUnit = HealthKitTypeCatalog.preferredUnit(for: type).unitString
                result[metric.id] = rows.compactMap { raw in
                    guard raw.unit == expectedUnit, raw.value.isFinite, raw.value > 0, raw.endAt >= raw.startAt else { return nil }
                    let source = [raw.sourceBundleId ?? "unknown", raw.deviceName ?? "", raw.deviceModel ?? ""].joined(separator: "|")
                    let name = [raw.sourceName, raw.deviceName, raw.deviceModel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    return TrainingMetricValue(id: raw.sampleUUID, date: Date(timeIntervalSince1970: Double(raw.startAt)),
                        value: raw.value * (metric == .oxygen ? 100 : 1), source: source,
                        sourceName: name.isEmpty ? "来源未标注" : name)
                }
            }
        }
        return result
    }

    static func heartSeries(_ samples: [TrainingSample], since: Date) -> [TrainingMetricValue] {
        let grouped = Dictionary(grouping: samples.filter {
            $0.type == TrainingTypes.heart && $0.start >= since && (25...230).contains($0.value)
        }) { "\($0.source)|\(Int($0.start.timeIntervalSince1970 / 1800))" }
        return grouped.compactMap { key, samples in
            guard let first = samples.first, let value = TrainingCalculator.median(samples.map(\.value)) else { return nil }
            return TrainingMetricValue(id: key, date: Date(timeIntervalSince1970: floor(first.start.timeIntervalSince1970 / 1800) * 1800),
                value: value, source: first.source, sourceName: first.sourceName, sampleCount: samples.count)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }
}
