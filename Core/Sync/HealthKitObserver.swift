import Foundation
import HealthKit

/// Subscribes to HealthKit change notifications and kicks an incremental sync whenever
/// any of our tracked sample types changes — including while the app is suspended,
/// because we also call `enableBackgroundDelivery(...)` per type.
///
/// Lifecycle:
/// - Call `start()` once authorization is granted (or partially granted).
/// - The observer registers one `HKObserverQuery` per `HKSampleType`.
/// - On change, fan-in into a single `SyncEngine.runIncremental(trigger: .observer)` call;
///   the SyncEngine's `isBusy` guard collapses bursts so we don't queue redundant runs.
/// - `stop()` removes the queries and disables background delivery (used in tests / sign-out).
///
/// Why HKObserverQuery + background delivery (not just BG App Refresh):
/// PRD F-001 wants "≤ 1 hour from source write to dashboard." Observer fires within seconds
/// when HealthKit applies a write; BG App Refresh is only a fallback for cases where the
/// observer didn't run (system pressure, app force-quit).
@MainActor
final class HealthKitObserver {

    private let healthKitManager: HealthKitManager
    private let syncEngine: SyncEngine
    private var activeQueries: [HKObserverQuery] = []
    private var didStart = false

    init(healthKitManager: HealthKitManager, syncEngine: SyncEngine) {
        self.healthKitManager = healthKitManager
        self.syncEngine = syncEngine
    }

    /// Safe to call multiple times; subsequent calls are no-ops.
    func start() {
        guard !didStart else { return }
        guard healthKitManager.isAvailable else {
            AppLogger.shared.healthkit.info("HealthKitObserver.start skipped: HK unavailable")
            return
        }
        didStart = true

        let store = healthKitManager.store
        let sampleTypes = HealthKitTypeCatalog.allReadSampleTypes

        for sampleType in sampleTypes {
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                if let error {
                    AppLogger.shared.healthkit.error(
                        "Observer fired with error for \(sampleType.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    completionHandler()
                    return
                }
                AppLogger.shared.healthkit.info(
                    "Observer fired: \(sampleType.identifier, privacy: .public)"
                )
                // Hop to MainActor to call into SyncEngine; completionHandler must be invoked
                // once the work is done so HealthKit can release the background assertion.
                Task { @MainActor [weak self] in
                    await self?.syncEngine.runIncremental(trigger: .observer)
                    completionHandler()
                }
            }
            store.execute(query)
            activeQueries.append(query)

            // Background delivery is what lets the observer fire while the app is suspended.
            // `.immediate` is appropriate per PRD F-001 (low-latency target).
            store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error {
                    AppLogger.shared.healthkit.error(
                        "enableBackgroundDelivery failed for \(sampleType.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                } else if !success {
                    AppLogger.shared.healthkit.warning(
                        "enableBackgroundDelivery returned false for \(sampleType.identifier, privacy: .public)"
                    )
                }
            }
        }

        AppLogger.shared.healthkit.info("HealthKitObserver started with \(self.activeQueries.count) queries")
    }

    func stop() {
        let store = healthKitManager.store
        for query in activeQueries {
            store.stop(query)
        }
        activeQueries.removeAll()
        store.disableAllBackgroundDelivery { _, error in
            if let error {
                AppLogger.shared.healthkit.error(
                    "disableAllBackgroundDelivery failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        didStart = false
    }
}
