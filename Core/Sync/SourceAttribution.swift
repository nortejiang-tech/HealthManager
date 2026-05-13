import Foundation

/// Determines which upstream app/device a sample originated from.
///
/// Policy per PRD §4.1: 不预过滤 source, 仅在采集后做归因展示与冲突告警。
/// 这里只做识别 + 归一化标签，不做删除/覆盖。
enum SourceAttribution {

    enum Origin: String, Codable {
        case garmin
        case xiaomiMijia
        case xiaomiSports
        case apple
        case hutool                  // 华为/华米等其他
        case manual
        case unknown
    }

    /// Best-effort mapping based on bundle id + source name. Add new mappings here as new
    /// devices appear in the wild — never drop a sample just because we don't recognise it.
    static func classify(bundleId: String?, sourceName: String?) -> Origin {
        let bid = (bundleId ?? "").lowercased()
        let name = (sourceName ?? "").lowercased()

        if bid.contains("garmin") || name.contains("garmin") {
            return .garmin
        }
        if bid.contains("mijia") || name.contains("mijia") || name.contains("米家") {
            return .xiaomiMijia
        }
        if bid.contains("xiaomi") || bid.contains("mi.fit")
            || name.contains("xiaomi") || name.contains("小米运动") || name.contains("zepp") {
            return .xiaomiSports
        }
        if bid.hasPrefix("com.apple.") || name == "health" || name.contains("apple") || name.contains("watch") {
            return .apple
        }
        if bid.contains("huawei") || name.contains("huawei") || name.contains("华为") {
            return .hutool
        }
        if bid.contains("com.norte.healthmanager") {
            return .manual
        }
        return .unknown
    }
}
