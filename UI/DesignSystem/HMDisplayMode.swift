import SwiftUI

/// The presentation mode chosen by the user for health data surfaces.
///
/// This type is intentionally storage-free: it never reads `UserDefaults`
/// itself. The app root owns persistence (for example `@AppStorage`) and
/// publishes the resolved value through the environment.
enum HMDisplayMode: String, CaseIterable, Identifiable, Sendable {
    /// Contemporary card layout with charts and metric tiles.
    case cards
    /// Legacy, list-first layout kept for continuity.
    case classic

    /// Stable `UserDefaults` key owned by the app root.
    static let storageKey = "hm.display.mode.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return "活力卡片"
        case .classic: return "经典"
        }
    }

    var subtitle: String {
        switch self {
        case .cards: return "以卡片和图表呈现健康数据"
        case .classic: return "沿用较早的列表式界面"
        }
    }

    /// Map a persisted raw value to a mode, falling back to `.cards`
    /// for unknown or missing values.
    static func resolve(_ raw: String) -> HMDisplayMode {
        HMDisplayMode(rawValue: raw) ?? .cards
    }
}

private struct HMDisplayModeKey: EnvironmentKey {
    static let defaultValue: HMDisplayMode = .cards
}

extension EnvironmentValues {
    /// The display mode shared with descendant views.
    var hmDisplayMode: HMDisplayMode {
        get { self[HMDisplayModeKey.self] }
        set { self[HMDisplayModeKey.self] = newValue }
    }
}
