import Foundation
import GRDB

enum TrainingSnapshotLoader {
    /// One consistent, bounded reader transaction. No new tables, writes or full-history scans.
    static func load(database: DatabaseManager, now: Date = Date(), calendar: Calendar = .current) async throws -> TrainingSnapshot {
        let begin = calendar.date(byAdding: .day, value: -TrainingCalculator.historyDays,
                                  to: calendar.startOfDay(for: now))!
        return try await database.asyncRead { db in
            let placeholders = TrainingTypes.inputs.map { _ in "?" }.joined(separator: ",")
            var args = StatementArguments(TrainingTypes.inputs)
            args += StatementArguments([begin.timeIntervalSince1970, now.timeIntervalSince1970])
            let raw = try HealthSampleRaw.fetchAll(db, sql: """
                SELECT * FROM health_samples_raw
                WHERE hk_type IN (\(placeholders)) AND is_deleted = 0
                  AND start_at >= ? AND start_at <= ?
                ORDER BY start_at, sample_uuid
                """, arguments: args)
            let samples = raw.compactMap(sample)
            let health = try healthMetrics(db, now: now, calendar: calendar)
            return TrainingCalculator.snapshot(samples: samples, health: health, now: now, calendar: calendar)
        }
    }

    static func sample(_ raw: HealthSampleRaw) -> TrainingSample? {
        guard !raw.isDeleted, raw.value.isFinite else { return nil }
        switch raw.hkType {
        case TrainingTypes.heart, TrainingTypes.resting:
            guard raw.unit == "count/min" else { return nil }
        case TrainingTypes.hrv:
            guard raw.unit == "ms" else { return nil }
        case TrainingTypes.sleep:
            guard raw.unit == "category", [0.0, 1, 2, 3, 4, 5].contains(raw.value) else { return nil }
        case TrainingTypes.workout:
            guard raw.unit == "second" else { return nil }
        default: return nil
        }
        var extra: [String: Any] = [:]
        if let json = raw.extraJson, let data = json.data(using: .utf8) {
            extra = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let metadata = extra["metadata"] as? [String: Any] ?? [:]
        let contextValue = metadata["HKHeartRateMotionContext"] ?? metadata["HKMetadataKeyHeartRateMotionContext"]
        let context = (contextValue as? NSNumber)?.intValue ?? (contextValue as? String).flatMap(Int.init)
        return TrainingSample(id: raw.sampleUUID, type: raw.hkType, value: raw.value,
            start: Date(timeIntervalSince1970: Double(raw.startAt)),
            end: Date(timeIntervalSince1970: Double(raw.endAt)),
            source: raw.sourceBundleId.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown:\(raw.sourceName ?? "未标注")",
            sourceName: raw.sourceName ?? "来源未标注", origin: raw.sourceOrigin ?? "unknown",
            ingestedAt: Date(timeIntervalSince1970: Double(raw.ingestedAt)),
            activityType: (extra["activityType"] as? NSNumber)?.intValue,
            duration: (extra["duration"] as? NSNumber)?.doubleValue,
            distance: (extra["totalDistanceMeters"] as? NSNumber)?.doubleValue, motionContext: context)
    }

    private static func healthMetrics(_ db: Database, now: Date, calendar: Calendar) throws -> [TrainingHealthMetric] {
        let cutoff = TrainingCalculator.dayKey(now, calendar)
        let earliest = TrainingCalculator.dayKey(calendar.date(byAdding: .day, value: -56, to: now)!, calendar)
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var metrics: [TrainingHealthMetric] = []
        let specs: [(String, String, String, String, Double)] = [
            ("activity_metrics_daily", "vo2_max", "VO₂max（设备估计）", "ml/kg/min", 1),
            ("activity_metrics_daily", "resting_hr_bpm", "静息心率", "bpm", 1),
            ("body_metrics_daily", "weight_kg", "体重", "kg", 1),
            ("body_metrics_daily", "body_fat_pct", "体脂率", "%", 100),
            ("body_metrics_daily", "lean_mass_kg", "瘦体重", "kg", 1)
        ]
        for (table, column, title, unit, multiplier) in specs {
            let rows = try Row.fetchAll(db, sql: """
                SELECT date, \(column) AS value FROM \(table)
                WHERE date >= ? AND date <= ? AND \(column) IS NOT NULL ORDER BY date
                """, arguments: [earliest, cutoff])
            let history = rows.compactMap { row -> TrainingMetricValue? in
                guard let value: Double = row["value"], value.isFinite, value > 0,
                      let key: String = row["date"], let date = f.date(from: key) else { return nil }
                return TrainingMetricValue(id: key, date: date, value: value * multiplier)
            }
            if let latest = history.last {
                metrics.append(TrainingHealthMetric(id: column, title: title, value: latest.value,
                                                    unit: unit, measuredOn: latest.date, history: history))
            }
        }
        let rawSpecs: [(String, String, String, Double)] = [
            ("HKQuantityTypeIdentifierRespiratoryRate", "呼吸频率", "次/分", 1),
            ("HKQuantityTypeIdentifierOxygenSaturation", "血氧", "%", 100),
            ("HKQuantityTypeIdentifierBloodPressureSystolic", "收缩压", "mmHg", 1),
            ("HKQuantityTypeIdentifierBloodPressureDiastolic", "舒张压", "mmHg", 1),
            ("HKQuantityTypeIdentifierBodyTemperature", "体温", "℃", 1)
        ]
        for (type, title, unit, multiplier) in rawSpecs {
            let records = try HealthSampleRaw.fetchAll(db, sql: """
                SELECT * FROM health_samples_raw WHERE hk_type = ? AND is_deleted = 0
                  AND start_at >= ? AND end_at <= ? ORDER BY start_at
                """, arguments: [type, now.addingTimeInterval(-56 * 86_400).timeIntervalSince1970, now.timeIntervalSince1970])
            let history = records.filter { $0.value.isFinite && $0.value > 0 }.map {
                TrainingMetricValue(id: $0.sampleUUID, date: Date(timeIntervalSince1970: Double($0.startAt)), value: $0.value * multiplier)
            }
            if let latest = history.last {
                metrics.append(TrainingHealthMetric(id: type, title: title, value: latest.value,
                    unit: unit, measuredOn: latest.date, history: history))
            }
        }
        return metrics
    }
}
