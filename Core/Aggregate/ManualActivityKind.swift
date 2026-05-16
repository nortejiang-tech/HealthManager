import Foundation

enum ManualActivityKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case soccer
    case basketball
    case baseball

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .soccer: return "足球"
        case .basketball: return "篮球"
        case .baseball: return "棒球"
        }
    }

    var systemImage: String {
        switch self {
        case .soccer: return "soccerball"
        case .basketball: return "basketball"
        case .baseball: return "baseball"
        }
    }

    /// Moderate recreational MET values. Calories = MET × weight(kg) × hours.
    var met: Double {
        switch self {
        case .soccer: return 7.0
        case .basketball: return 6.5
        case .baseball: return 5.0
        }
    }

    /// Used only when the user enters distance but leaves duration empty.
    var defaultSpeedKmH: Double {
        switch self {
        case .soccer: return 7.0
        case .basketball: return 5.0
        case .baseball: return 4.0
        }
    }

    var workoutActivityTypeRaw: Int {
        switch self {
        case .baseball: return 5
        case .basketball: return 6
        case .soccer: return 41
        }
    }

    static func displayName(forRawValue rawValue: String?) -> String? {
        guard let rawValue, let kind = ManualActivityKind(rawValue: rawValue) else { return nil }
        return kind.displayName
    }
}
