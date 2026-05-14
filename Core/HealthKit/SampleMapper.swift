import Foundation
import HealthKit

/// Converts HealthKit samples into our canonical `HealthSampleRaw` rows.
///
/// Design notes:
/// - **Never** drops a sample because of "unknown source" — attribution happens later.
/// - Workout / Category samples are represented by encoding their domain-specific fields
///   into `extra_json` so the same flat table can hold every kind of sample.
enum SampleMapper {

    /// Top-level convert entry. Returns a row ready to be inserted into `health_samples_raw`.
    static func map(_ sample: HKSample, ingestedAt: Date = Date()) -> HealthSampleRaw? {
        if let q = sample as? HKQuantitySample {
            return mapQuantity(q, ingestedAt: ingestedAt)
        }
        if let c = sample as? HKCategorySample {
            return mapCategory(c, ingestedAt: ingestedAt)
        }
        if let w = sample as? HKWorkout {
            return mapWorkout(w, ingestedAt: ingestedAt)
        }
        return nil
    }

    private static func mapQuantity(_ sample: HKQuantitySample, ingestedAt: Date) -> HealthSampleRaw {
        let unit = HealthKitTypeCatalog.preferredUnit(for: sample.quantityType)
        let value = sample.quantity.doubleValue(for: unit)
        let extra = makeExtra(metadata: sample.metadata)
        let bundleId = sample.sourceRevision.source.bundleIdentifier
        let sourceName = sample.sourceRevision.source.name

        return HealthSampleRaw(
            sampleUUID: sample.uuid.uuidString,
            hkType: sample.quantityType.identifier,
            kind: .quantity,
            value: value,
            unit: unit.unitString,
            startAt: Int64(sample.startDate.timeIntervalSince1970),
            endAt: Int64(sample.endDate.timeIntervalSince1970),
            sourceName: sourceName,
            sourceBundleId: bundleId,
            deviceName: sample.device?.name,
            deviceModel: sample.device?.model,
            ingestedAt: Int64(ingestedAt.timeIntervalSince1970),
            isDeleted: false,
            extraJson: extra,
            sourceOrigin: SourceAttribution.classify(bundleId: bundleId, sourceName: sourceName).rawValue
        )
    }

    private static func mapCategory(_ sample: HKCategorySample, ingestedAt: Date) -> HealthSampleRaw {
        var extraDict: [String: Any] = [
            "categoryValue": sample.value
        ]
        if let meta = sample.metadata {
            extraDict["metadata"] = stringifyMetadata(meta)
        }
        // Decode sleep stages into a friendly label so downstream queries don't need to remap.
        if sample.categoryType.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue,
           let stage = HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            extraDict["sleepStage"] = sleepStageLabel(stage)
        }

        let bundleId = sample.sourceRevision.source.bundleIdentifier
        let sourceName = sample.sourceRevision.source.name
        return HealthSampleRaw(
            sampleUUID: sample.uuid.uuidString,
            hkType: sample.categoryType.identifier,
            kind: .category,
            value: Double(sample.value),
            unit: "category",
            startAt: Int64(sample.startDate.timeIntervalSince1970),
            endAt: Int64(sample.endDate.timeIntervalSince1970),
            sourceName: sourceName,
            sourceBundleId: bundleId,
            deviceName: sample.device?.name,
            deviceModel: sample.device?.model,
            ingestedAt: Int64(ingestedAt.timeIntervalSince1970),
            isDeleted: false,
            extraJson: jsonString(extraDict),
            sourceOrigin: SourceAttribution.classify(bundleId: bundleId, sourceName: sourceName).rawValue
        )
    }

    private static func mapWorkout(_ workout: HKWorkout, ingestedAt: Date) -> HealthSampleRaw {
        var extra: [String: Any] = [
            "activityType": workout.workoutActivityType.rawValue,
            "duration": workout.duration
        ]
        if let energy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
            extra["totalEnergyKcal"] = energy
        }
        if let distance = workout.totalDistance?.doubleValue(for: .meter()) {
            extra["totalDistanceMeters"] = distance
        }
        if let meta = workout.metadata {
            extra["metadata"] = stringifyMetadata(meta)
        }

        let bundleId = workout.sourceRevision.source.bundleIdentifier
        let sourceName = workout.sourceRevision.source.name
        return HealthSampleRaw(
            sampleUUID: workout.uuid.uuidString,
            hkType: HKWorkoutTypeIdentifier,
            kind: .workout,
            value: workout.duration,
            unit: "second",
            startAt: Int64(workout.startDate.timeIntervalSince1970),
            endAt: Int64(workout.endDate.timeIntervalSince1970),
            sourceName: sourceName,
            sourceBundleId: bundleId,
            deviceName: workout.device?.name,
            deviceModel: workout.device?.model,
            ingestedAt: Int64(ingestedAt.timeIntervalSince1970),
            isDeleted: false,
            extraJson: jsonString(extra),
            sourceOrigin: SourceAttribution.classify(bundleId: bundleId, sourceName: sourceName).rawValue
        )
    }

    // MARK: - Helpers

    private static func makeExtra(metadata: [String: Any]?) -> String? {
        guard let metadata, !metadata.isEmpty else { return nil }
        return jsonString(["metadata": stringifyMetadata(metadata)])
    }

    private static func stringifyMetadata(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw {
            if let s = v as? String { out[k] = s }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
            else if let d = v as? Date { out[k] = ISO8601DateFormatter().string(from: d) }
            else { out[k] = String(describing: v) }
        }
        return out
    }

    private static func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func sleepStageLabel(_ stage: HKCategoryValueSleepAnalysis) -> String {
        switch stage {
        case .inBed: return "inBed"
        case .asleepUnspecified: return "asleepUnspecified"
        case .awake: return "awake"
        case .asleepCore: return "asleepCore"
        case .asleepDeep: return "asleepDeep"
        case .asleepREM: return "asleepREM"
        @unknown default: return "unknown"
        }
    }
}

/// Re-export of the HealthKit workout type identifier so persistence layer doesn't need to import HealthKit.
let HKWorkoutTypeIdentifier = "HKWorkoutTypeIdentifier"
