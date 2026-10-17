import Foundation
import GRDB

enum TrainingSnapshotLoader {
    /// One consistent, bounded reader transaction. No new tables, writes or full-history scans.
    static func load(database: DatabaseManager, now: Date = Date(), calendar: Calendar = .current) async throws -> TrainingSnapshot {
        let begin = calendar.date(byAdding: .day, value: -TrainingCalculator.inputHistoryDays,
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
            var parameters = try TrainingParameterLoader.load(db, now: now, calendar: calendar)
            let displayStart = calendar.date(byAdding: .day, value: -55, to: calendar.startOfDay(for: now))!
            parameters[TrainingMetric.heart.id] = TrainingParameterLoader.heartSeries(samples, since: displayStart)
            var snapshot = TrainingCalculator.snapshot(samples: samples, now: now, calendar: calendar)
            snapshot.parameters = parameters
            return snapshot
        }
    }

    static func session(database: DatabaseManager, id: String, now: Date = Date(), calendar: Calendar = .current) async throws -> TrainingSession? {
        try await database.asyncRead { db in
            guard let record = try HealthSampleRaw.fetchOne(db, key: id), record.hkType == TrainingTypes.workout,
                  let workout = sample(record) else { return nil }
            let types = TrainingTypes.inputs.map { _ in "?" }.joined(separator: ",")
            var arguments = StatementArguments(TrainingTypes.inputs)
            arguments += StatementArguments([workout.start.addingTimeInterval(-57 * 86400).timeIntervalSince1970,
                min(now, workout.end.addingTimeInterval(135)).timeIntervalSince1970, now.timeIntervalSince1970, now.timeIntervalSince1970])
            let raw = try HealthSampleRaw.fetchAll(db, sql: """
                SELECT * FROM health_samples_raw WHERE hk_type IN (\(types)) AND is_deleted = 0
                AND start_at >= ? AND start_at <= ? AND end_at <= ? AND ingested_at <= ? ORDER BY start_at, sample_uuid
                """, arguments: arguments)
            return TrainingCalculator.recordDetail(id: id, samples: raw.compactMap(sample), now: now, calendar: calendar)
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
            distance: (extra["totalDistanceMeters"] as? NSNumber)?.doubleValue, motionContext: context,
            energyKcal: (extra["totalEnergyKcal"] as? NSNumber)?.doubleValue)
    }

}
