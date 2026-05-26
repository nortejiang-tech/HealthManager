import Foundation
import SwiftUI

/// Catalogue of every card the摘要 grid can show.
///
/// "Rich" kinds (activity / heart / sleep / body / diet / deficit) are the original
/// info-dense cards — they keep their bespoke layouts. "Slim" kinds are single-metric
/// stat tiles built from the shared `SlimMetricCard`. The user can toggle either
/// flavor in/out of the main grid via the editor sheet; whatever isn't in the grid
/// shows up under "更多指标".
enum DashboardCardKind: String, Codable, CaseIterable, Identifiable {
    // Rich (existing) cards
    case activity, heart, sleep, body, diet, deficit
    // Slim single-metric cards
    case activeKcal, distance, bodyFat, bmi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .activity: return "活动"
        case .heart: return "心率"
        case .sleep: return "睡眠"
        case .body: return "体重 / 体成分"
        case .diet: return "饮食"
        case .deficit: return "热量缺口"
        case .activeKcal: return "活动能量"
        case .distance: return "距离"
        case .bodyFat: return "体脂率"
        case .bmi: return "BMI"
        }
    }

    var iconName: String {
        switch self {
        case .activity: return "figure.walk"
        case .heart: return "heart.fill"
        case .sleep: return "bed.double.fill"
        case .body: return "figure.arms.open"
        case .diet: return "fork.knife"
        case .deficit: return "flame.fill"
        case .activeKcal: return "flame.fill"
        case .distance: return "figure.walk.motion"
        case .bodyFat: return "figure"
        case .bmi: return "scalemass.fill"
        }
    }

    var theme: CardTheme {
        switch self {
        case .activity, .activeKcal, .distance: return .activity
        case .heart: return .heart
        case .sleep: return .sleep
        case .body, .bodyFat, .bmi: return .body
        case .diet: return .diet
        case .deficit: return .deficit
        }
    }

    var route: MetricRoute {
        switch self {
        case .activity: return .activity
        case .heart: return .restingHR
        case .sleep: return .sleep
        case .body: return .weight
        case .diet: return .diet
        case .deficit: return .deficit
        case .activeKcal: return .activeKcal
        case .distance: return .distance
        case .bodyFat: return .bodyFat
        case .bmi: return .bmi
        }
    }

    var isRich: Bool {
        switch self {
        case .activity, .heart, .sleep, .body, .diet, .deficit: return true
        default: return false
        }
    }

    /// Default top-of-dashboard layout — matches the pre-customization v1 grid.
    static let defaults: [DashboardCardKind] = [
        .activity, .heart, .sleep, .body, .diet, .deficit
    ]
}

/// Persistent store of which cards appear in the main grid and in what order.
/// Hidden cards (those in `allCases` but not in `visibleCards`) render under
/// "更多指标" as compact rows.
@MainActor
final class DashboardLayoutStore: ObservableObject {
    @Published var visibleCards: [DashboardCardKind] = DashboardCardKind.defaults {
        didSet { persist() }
    }

    private static let storageKey = "dashboard.layout.visibleCards.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DashboardCardKind].self, from: data),
           !decoded.isEmpty {
            self.visibleCards = decoded
        }
    }

    /// All catalog entries that aren't in the visible grid right now. Preserves
    /// `allCases` order so the "更多指标" rows stay stable across edits.
    var hiddenCards: [DashboardCardKind] {
        DashboardCardKind.allCases.filter { !visibleCards.contains($0) }
    }

    func show(_ kind: DashboardCardKind) {
        guard !visibleCards.contains(kind) else { return }
        visibleCards.append(kind)
    }

    func hide(_ kind: DashboardCardKind) {
        visibleCards.removeAll { $0 == kind }
    }

    func move(from source: IndexSet, to destination: Int) {
        visibleCards.move(fromOffsets: source, toOffset: destination)
    }

    func resetToDefaults() {
        visibleCards = DashboardCardKind.defaults
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(visibleCards) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
