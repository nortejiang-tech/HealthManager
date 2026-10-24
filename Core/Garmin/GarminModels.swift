import Foundation
import CoreFoundation

enum GarminMetric: String, Codable, CaseIterable, Sendable {
    case hrv, sleep, bodyBattery, stress
    var title: String {
        switch self {
        case .hrv: return "夜间 HRV"
        case .sleep: return "睡眠评分"
        case .bodyBattery: return "Body Battery"
        case .stress: return "今日压力"
        }
    }
    var unit: String { self == .hrv ? "ms" : "" }
}

struct GarminPoint: Codable, Equatable, Sendable {
    let timestamp: Double
    let value: Double
}

/// Vendor-defined metrics stay separate from HealthKit SDNN and local readiness.
struct GarminMetricPayload: Codable, Equatable, Sendable {
    var values: [String: Double] = [:]
    var labels: [String: String] = [:]
    var points: [GarminPoint] = []
    var observedAt: Double?
    var primary: Double? { values["primary"] }
}

struct GarminMetricRecord: Identifiable, Equatable, Sendable {
    let id: String
    let date: String
    let metric: GarminMetric
    let payload: GarminMetricPayload?
    let fetchedAt: Date?
    let lastAttemptAt: Date
    let state: String
    var isStale: Bool { state != "available" || fetchedAt.map { Date().timeIntervalSince($0) > 86400 } != false }
}

enum GarminNormalizer {
    /// Boolean-backed NSNumbers are never valid timestamps.
    private static func isBooleanNumber(_ v: NSNumber) -> Bool {
        return CFGetTypeID(v) == CFBooleanGetTypeID()
    }

    /// Only finite, strictly positive epoch seconds may escape normalization.
    private static func positiveFinite(_ seconds: Double) -> Double? {
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    static func timestamp(_ value: Any?) -> Double? {
        if let v = value as? NSNumber {
            if isBooleanNumber(v) { return nil }
            let n = v.doubleValue
            return positiveFinite(n).map { $0 > 10_000_000_000 ? $0 / 1000 : $0 }
        }
        guard let text = value as? String else { return nil }
        if let n = Double(text) { return timestamp(NSNumber(value: n)) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return positiveFinite(d.timeIntervalSince1970) }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return positiveFinite(d.timeIntervalSince1970) }
        // Only call this for fields explicitly defined as GMT by Garmin.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = format
            if let d = f.date(from: text) { return positiveFinite(d.timeIntervalSince1970) }
        }
        return nil
    }
    static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !isBooleanNumber(n), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func normalize(_ metric: GarminMetric, object: Any, date: String) -> GarminMetricPayload? {
        var result = GarminMetricPayload()
        switch metric {
        case .hrv:
            guard let root = object as? [String: Any], let summary = root["hrvSummary"] as? [String: Any] else { return nil }
            for (source, target) in [("lastNightAvg", "primary"), ("weeklyAvg", "weeklyAverage"), ("lastNight5MinHigh", "fiveMinuteHigh")] {
                if let n = number(summary[source]), n > 0 && n <= 500 { result.values[target] = n }
            }
            if let status = summary["status"] as? String,
               ["NONE", "POOR", "LOW", "UNBALANCED", "BALANCED", "INVALID"].contains(status) { result.labels["status"] = status }
            if let baseline = summary["baseline"] as? [String: Any] {
                for key in ["balancedLow", "balancedUpper", "lowUpper"] {
                    if let n = number(baseline[key]), n > 0 { result.values[key] = n }
                }
            }
            result.points = (root["hrvReadings"] as? [[String: Any]] ?? []).compactMap {
                guard let v = number($0["hrvValue"]), v > 0 && v <= 500,
                      let t = timestamp($0["readingTimeGMT"]) else { return nil }
                return GarminPoint(timestamp: t, value: v)
            }.sorted { $0.timestamp < $1.timestamp }
            result.observedAt = result.points.last?.timestamp
        case .sleep:
            guard let root = object as? [String: Any] else { return nil }
            // Score map keys are vendor-defined. Accept only known overall-score keys;
            // never choose the first arbitrary component score.
            if let scores = root["sleepScores"] as? [String: Any] {
                for (key, item) in scores where key.count <= 80 {
                    if let entry = item as? [String:Any], let n = number(entry["value"]), (0...100).contains(n) {
                        result.values["score." + key] = n
                    }
                }
                for key in ["overall", "overallScore", "totalScore"] {
                    if let score = scores[key] as? [String: Any], let n = number(score["value"]), (0...100).contains(n) {
                        result.values["primary"] = n; break
                    }
                }
            }
            for key in ["sleepTimeSeconds", "napTimeSeconds", "deepSleepSeconds", "lightSleepSeconds", "remSleepSeconds", "awakeSleepSeconds"] {
                if let n = number(root[key]), n >= 0 && n <= 86400 { result.values[key] = n }
            }
            guard result.values["primary"] != nil || (result.values["sleepTimeSeconds"] ?? 0) > 0 || result.values.keys.contains(where: { $0.hasPrefix("score.") }) else { return nil }
            result.observedAt = timestamp(root["sleepEndTimestampGMT"])
            if let confirmed = root["sleepWindowConfirmed"] as? Bool { result.labels["confirmed"] = confirmed ? "true" : "false" }
        case .bodyBattery:
            guard let root = (object as? [[String: Any]])?.first(where: { $0["date"] as? String == date }) else { return nil }
            let descriptors = root["bodyBatteryValueDescriptorDTOList"] as? [[String: Any]] ?? []
            guard let valueIndex = descriptors.first(where: { $0["bodyBatteryValueDescriptorKey"] as? String == "bodyBatteryLevel" })?["bodyBatteryValueDescriptorIndex"] as? Int,
                  let timeIndex = descriptors.first(where: { $0["bodyBatteryValueDescriptorKey"] as? String == "timestamp" })?["bodyBatteryValueDescriptorIndex"] as? Int,
                  valueIndex >= 0, timeIndex >= 0 else { return nil }
            result.points = (root["bodyBatteryValuesArray"] as? [[Any]] ?? []).compactMap {
                guard $0.count > max(valueIndex, timeIndex), let n = number($0[valueIndex]), (5...100).contains(n),
                      let t = timestamp($0[timeIndex]) else { return nil }
                return GarminPoint(timestamp: t, value: n)
            }.sorted { $0.timestamp < $1.timestamp }
            result.values["primary"] = result.points.last?.value
            result.observedAt = result.points.last?.timestamp
            for key in ["charged", "drained"] { if let n = number(root[key]), n >= 0 { result.values[key] = n } }
            result.labels["sampling"] = "chunk-extrema"
        case .stress:
            guard let root = (object as? [[String: Any]])?.first(where: { $0["calendarDate"] as? String == date }),
                  let values = root["values"] as? [String: Any] else { return nil }
            if let n = number(values["overallStressLevel"]), (0...100).contains(n) { result.values["primary"] = n }
            for key in ["lowStressDuration", "mediumStressDuration", "highStressDuration", "restStressDuration"] {
                if let n = number(values[key]), n >= 0 { result.values[key] = n }
            }
        }
        return result.values.isEmpty && result.points.isEmpty ? nil : result
    }
}
