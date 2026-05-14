import Foundation

/// User-editable reconciler thresholds backed by `UserDefaults`.
///
/// `DailyReconciler.Config` reads from this on every `run()` so changes in
/// the Settings UI take effect on the next pass without restart.
enum ReconcilerSettings {

    enum Key {
        static let completenessThreshold = "reconcile.completenessWarningThreshold"
        static let conflictMinSources = "reconcile.conflictMinSources"
        static let consecutiveMissingForCritical = "reconcile.consecutiveMissingForCritical"
        static let defaultWindowDays = "reconcile.defaultWindowDays"
        static let coreMetrics = "reconcile.coreMetrics"
    }

    static let defaultCoreMetrics: [String] = [
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierHeartRate",
        "HKCategoryTypeIdentifierSleepAnalysis"
    ]

    static var completenessThreshold: Double {
        get { readDouble(Key.completenessThreshold, fallback: 0.75) }
        set { UserDefaults.standard.set(clamp(newValue, 0.1, 1.0), forKey: Key.completenessThreshold) }
    }

    static var conflictMinSources: Int {
        get { readInt(Key.conflictMinSources, fallback: 2) }
        set { UserDefaults.standard.set(max(2, min(10, newValue)), forKey: Key.conflictMinSources) }
    }

    static var consecutiveMissingForCritical: Int {
        get { readInt(Key.consecutiveMissingForCritical, fallback: 3) }
        set { UserDefaults.standard.set(max(1, min(30, newValue)), forKey: Key.consecutiveMissingForCritical) }
    }

    static var defaultWindowDays: Int {
        get { readInt(Key.defaultWindowDays, fallback: 7) }
        set { UserDefaults.standard.set(max(1, min(90, newValue)), forKey: Key.defaultWindowDays) }
    }

    static var coreMetrics: [String] {
        get {
            (UserDefaults.standard.array(forKey: Key.coreMetrics) as? [String]) ?? defaultCoreMetrics
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.coreMetrics)
        }
    }

    static func resetToDefaults() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Key.completenessThreshold)
        d.removeObject(forKey: Key.conflictMinSources)
        d.removeObject(forKey: Key.consecutiveMissingForCritical)
        d.removeObject(forKey: Key.defaultWindowDays)
        d.removeObject(forKey: Key.coreMetrics)
    }

    // MARK: - Helpers

    private static func readDouble(_ key: String, fallback: Double) -> Double {
        let v = UserDefaults.standard.object(forKey: key) as? Double
        return v ?? fallback
    }

    private static func readInt(_ key: String, fallback: Int) -> Int {
        let v = UserDefaults.standard.object(forKey: key) as? Int
        return v ?? fallback
    }

    private static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(x, lo), hi)
    }
}
