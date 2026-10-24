import Foundation

/// Feature-local immutable inputs. No HealthKit queries or writes in the calculator.
struct TrainingSample: Sendable, Hashable {
    var id: String
    var type: String
    var value: Double
    var start: Date
    var end: Date
    var source: String
    var sourceName: String
    var origin: String
    var ingestedAt: Date
    var activityType: Int? = nil
    var duration: Double? = nil
    var distance: Double? = nil
    var motionContext: Int? = nil
    var energyKcal: Double? = nil
}

enum TrainingTypes {
    static let workout = "HKWorkoutTypeIdentifier"
    static let heart = "HKQuantityTypeIdentifierHeartRate"
    static let hrv = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    static let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    static let resting = "HKQuantityTypeIdentifierRestingHeartRate"
    static let inputs = [workout, heart, hrv, sleep, resting]
}

struct TrainingSession: Identifiable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let activityType: Int
    let minutes: Double
    let distanceKm: Double?
    let source: String
    let sourceName: String
    let averageHeartRate: Double?
    let peakHeartRate: Double?
    let heartCoverage: Double
    let load: Double?
    let restingReference: Double?
    let restingMethod: String
    let recovery60: Double?
    let recovery120: Double?
    let notes: [String]
    var energyKcal: Double? = nil

    var isRun: Bool { activityType == 37 }
    var paceSecondsPerKm: Double? {
        guard let distanceKm, distanceKm > 0 else { return nil }
        return minutes * 60 / distanceKm
    }
}

struct TrainingNight: Identifiable, Sendable {
    var id: String { dayKey }
    let dayKey: String
    let wakeDay: Date
    let start: Date
    let end: Date
    let source: String
    let hours: Double
    let hrv: Double?
    let hrvCount: Int
    let heartRate: Double?
    let heartCount: Int
    let hrvSpanHours: Double
    let heartSpanHours: Double
    let hasConflict: Bool
    var stageHours: [Int: Double] = [:]
    var qualifiesForBaseline: Bool {
        !source.hasPrefix("unknown") && hrvCount >= 3 && heartCount >= 12 && hrvSpanHours >= 1 && heartSpanHours >= 1
            && hours >= 1.5 && !hasConflict
    }
}

struct TrainingDay: Identifiable, Sendable {
    var id: String { key }
    let key: String
    let date: Date
    var runKm: Double = 0
    var runMinutes: Double = 0
    var sessionCount: Int = 0
    var recordedLoad: Double? = nil
    var missingLoadCount: Int = 0
    var missingDistanceCount: Int = 0
    var night: TrainingNight? = nil
}

struct TrainingFactor: Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
    let penalty: Double?
    let detail: String
}

struct TrainingReadiness: Sendable {
    static let version = "恢复准备度 v2 · 睡后评估 · 实验"
    let score: Int?
    let credibility: String
    let baselineNights: Int
    let factors: [TrainingFactor]
    let missingReasons: [String]
    let observedAt: Date?
    /// Bounds caused only by an unknown load penalty, not a statistical confidence interval.
    var possibleRange: ClosedRange<Int>? = nil
    var source: String = ""
    var referenceRange: ClosedRange<Double>? = nil
    var referenceCount: Int = 0
    var previousScore: Int? = nil
    var previousDate: Date? = nil
}

struct TrainingReadinessPoint: Identifiable, Sendable {
    let id: String
    let date: Date
    let assessment: TrainingReadiness
}

struct TrainingHealthMetric: Identifiable, Sendable {
    let id: String
    let title: String
    let value: Double
    let unit: String
    let measuredOn: Date
    var history: [TrainingMetricValue] = []
}

struct TrainingMetricValue: Identifiable, Sendable {
    let id: String
    let date: Date
    let value: Double
    var source: String = ""
    var sourceName: String = ""
    var sampleCount: Int? = nil
}

struct TrainingRecoveryWindow: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let heartRate: Double
    let sampleCount: Int
}

struct TrainingRunComparison: Sendable {
    let distanceKm: Double
    let recentPace: Double
    let earlierPace: Double
    let recentHeart: Double?
    let earlierHeart: Double?
    let recentCount: Int
    let earlierCount: Int
    var recentStart: Date? = nil
    var recentEnd: Date? = nil
    var earlierStart: Date? = nil
    var earlierEnd: Date? = nil
    var sourceName: String = ""
    var source: String = ""
}

struct TrainingSnapshot: Sendable {
    let calculatedAt: Date
    let latestMeasurementAt: Date?
    let latestIngestionAt: Date?
    let sessions: [TrainingSession]
    let days: [TrainingDay]
    let readiness: TrainingReadiness
    let health: [TrainingHealthMetric]
    let comparison: TrainingRunComparison?
    let intraday: [TrainingRecoveryWindow]
    var readinessHistory: [TrainingReadinessPoint] = []
    var parameters: [String: [TrainingMetricValue]] = [:]

    func recentDays(_ count: Int) -> [TrainingDay] { Array(days.suffix(count)) }
    var latestNight: TrainingNight? { days.compactMap(\.night).last }
}
