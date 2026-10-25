import Foundation
import GRDB

/// Shared selected-source daily values for dashboard, reports, and exported projections.
enum DailySourceProjection {
    static let effectiveDate = "2026-10-23"
    static let version = WorkoutEventResolver.policyVersion
    static func average(db: Database, type: String, start: Int64, end: Int64) throws -> Double? {
        let rows = try HealthSampleRaw.fetchAll(db, sql: """
            SELECT * FROM health_samples_raw WHERE hk_type=? AND is_deleted=0 AND start_at>=? AND start_at<=?
            ORDER BY start_at,sample_uuid
            """, arguments: [type, start, end])
        let valid = rows.filter { $0.value.isFinite }
        guard !valid.isEmpty else { return nil }
        if type == TrainingTypes.heart {
            let obs = valid.filter { (25...230).contains($0.value) }.map {
                SampleSourcePolicy.Observation(id: $0.sampleUUID, source: $0.sourceBundleId ?? "unknown:\($0.sourceName ?? "")",
                    origin: $0.sourceOrigin ?? SourceAttribution.classify(bundleId: $0.sourceBundleId, sourceName: $0.sourceName).rawValue,
                    start: Date(timeIntervalSince1970: Double($0.startAt)), end: Date(timeIntervalSince1970: Double($0.endAt)), value: $0.value)
            }
            let segments = SampleSourcePolicy.resolve(obs, from: Date(timeIntervalSince1970: Double(start)), to: Date(timeIntervalSince1970: Double(end + 1)))
            let seconds = segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            guard seconds > 0 else { return nil }
            return segments.reduce(0) { $0 + $1.observation.value * $1.end.timeIntervalSince($1.start) } / seconds
        }
        let groups = Dictionary(grouping: valid, by: { $0.sourceBundleId ?? "unknown:\($0.sourceName ?? "")" })
        let chosen = groups.keys.sorted { a, b in
            let x = groups[a]![0], y = groups[b]![0]
            let px = SampleSourcePolicy.priority(x.sourceOrigin ?? SourceAttribution.classify(bundleId: x.sourceBundleId, sourceName: x.sourceName).rawValue)
            let py = SampleSourcePolicy.priority(y.sourceOrigin ?? SourceAttribution.classify(bundleId: y.sourceBundleId, sourceName: y.sourceName).rawValue)
            return px == py ? a < b : px > py
        }.first!
        let values = groups[chosen]!.map(\.value)
        return values.reduce(0, +) / Double(values.count)
    }
    static func evidence(db: Database, start: Int64, end: Int64) throws -> String {
        let types = [TrainingTypes.heart,TrainingTypes.resting,TrainingTypes.hrv,"HKQuantityTypeIdentifierVO2Max"]
        var details: [String:[String:Double]] = [:]
        for type in types {
            let rows = try HealthSampleRaw.fetchAll(db,sql:"SELECT * FROM health_samples_raw WHERE hk_type=? AND is_deleted=0 AND start_at BETWEEN ? AND ? ORDER BY sample_uuid",arguments:[type,start,end]).filter { $0.value.isFinite }
            if type == TrainingTypes.heart {
                let observations = rows.filter { (25...230).contains($0.value) }.map {
                    SampleSourcePolicy.Observation(id:$0.sampleUUID,source:$0.sourceBundleId ?? "unknown",origin:$0.sourceOrigin ?? SourceAttribution.classify(bundleId:$0.sourceBundleId,sourceName:$0.sourceName).rawValue,start:Date(timeIntervalSince1970:Double($0.startAt)),end:Date(timeIntervalSince1970:Double($0.endAt)),value:$0.value)
                }
                for segment in SampleSourcePolicy.resolve(observations,from:Date(timeIntervalSince1970:Double(start)),to:Date(timeIntervalSince1970:Double(end+1))) {
                    details[type,default:[:]][segment.observation.source,default:0] += segment.end.timeIntervalSince(segment.start)
                }
            } else {
                let groups = Dictionary(grouping:rows,by:{ $0.sourceBundleId ?? "unknown" })
                if let source = groups.keys.sorted(by:{ a,b in
                    let pa = SampleSourcePolicy.priority(groups[a]![0].sourceOrigin ?? SourceAttribution.classify(bundleId:groups[a]![0].sourceBundleId,sourceName:groups[a]![0].sourceName).rawValue), pb = SampleSourcePolicy.priority(groups[b]![0].sourceOrigin ?? SourceAttribution.classify(bundleId:groups[b]![0].sourceBundleId,sourceName:groups[b]![0].sourceName).rawValue)
                    return pa == pb ? a < b : pa > pb
                }).first { details[type] = [source:Double(groups[source]!.count)] }
            }
        }
        var cumulative: [String:[String:String]] = [:]
        for type in ["HKQuantityTypeIdentifierStepCount",ActivityEnergyCalculator.activeEnergyType,"HKQuantityTypeIdentifierBasalEnergyBurned","HKQuantityTypeIdentifierDistanceWalkingRunning"] {
            let selected = try ActivityEnergyCalculator.dominantCumulativeSum(db:db,hkType:type,start:start,end:end)
            if let source = selected.sourceKey { cumulative[type] = ["source":source,"reason":selected.selectionReason] }
        }
        let sleepSource = try GarminStore.sleepSeconds(db:db,date:DashboardLoader.dateKey.string(from:Date(timeIntervalSince1970:Double(start)))) != nil ? "garmin_cn_personal" : "healthkit_selected_source"
        let manualWorkouts = try WorkoutEventProjection.events(db: db, start: start, end: end)
        let manualEnergy = manualWorkouts.filter(\.isManuallySelected).map { event -> [String:Any] in
            ["record": event.selected.id, "source": event.selected.source, "applied": ActivityEnergyCalculator.manualEnergyWindow(event, amongst: manualWorkouts) != nil,
             "method": "replace_represented_workout_window_keep_non_workout_energy"]
        }
        let data = try JSONSerialization.data(withJSONObject:["version":version,"sleepSource":sleepSource,"metricSources":details,"cumulativeSelections":cumulative,"heartWeight":"covered_seconds","otherWeight":"selected_source_sample_count","manualWorkoutEnergy":manualEnergy],options:[.sortedKeys])
        return String(decoding:data,as:UTF8.self)
    }

    static func hasSelectedRaw(db: Database, date: String, type: String, calendar: Calendar) throws -> Bool {
        guard date >= effectiveDate else { return false }
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: date), let next = calendar.date(byAdding: .day, value: 1, to: day) else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM health_samples_raw WHERE hk_type=? AND is_deleted=0 AND start_at>=? AND start_at<?)", arguments: [type, day.timeIntervalSince1970, next.timeIntervalSince1970]) ?? false
    }
}
