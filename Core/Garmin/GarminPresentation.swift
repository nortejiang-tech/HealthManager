import Foundation

/// A presentation selection preserves both the latest attempt and the last useful
/// measurement. A failed new day must never make an older value look current.
struct GarminPresentation {
    let metric: GarminMetric
    let latestAttempt: GarminMetricRecord?
    let displayed: GarminMetricRecord?

    init(metric: GarminMetric, records: [GarminMetricRecord]) {
        self.metric = metric
        let matching = records.filter { $0.metric == metric }.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.lastAttemptAt > $1.lastAttemptAt
        }
        latestAttempt = matching.first
        displayed = matching.first { $0.payload?.primary != nil }
            ?? matching.first { $0.payload != nil } ?? matching.first
    }

    var value: Double? { displayed?.payload?.primary }
    var status: String {
        if latestAttempt?.state == "error" { return value == nil ? "同步未完成" : "历史值 · 同步未完成" }
        if let displayed, let latestAttempt, displayed.date != latestAttempt.date {
            return "历史值 · 新数据未到"
        }
        if displayed?.state != "available", value != nil { return "历史值 · 待更新" }
        if value == nil {
            return metric == .sleep && displayed?.payload?.values["sleepTimeSeconds"] != nil
                ? "已有时长 · 暂无评分" : "暂无数据"
        }
        return displayed?.isStale == true ? "历史值 · 待更新" : "Garmin Connect"
    }
}

enum GarminPersonalAPICapabilities {
    // Reviewed against the official Personal API 1.0.0 schema (26 GET paths).
    // Device support is not API availability. No undocumented endpoint is tried.
    static let trainingReadinessAvailable = false
    static let reviewedDate = "2026-10-23"
    // Verified on the user's installed iOS Garmin Connect: the app registers the
    // `connect://` custom URL scheme. Never fall back to a browser or App Store.
    static let connectURL = URL(string: "connect://")!
    static let specificationURL = URL(string: "https://developer.garmin.com/gc-developer-program/personal/swagger-docs/")!
}
