import Foundation
import BackgroundTasks
import UIKit

/// BGTask wiring. The actual incremental work is delegated to `SyncEngine.runIncremental`.
/// Round 1 only registers + reschedules; the worker body fills in during Round 3.
@MainActor
final class BackgroundTaskScheduler {

    static let incrementalIdentifier = "com.norte.HealthManager.bgsync"
    static let reconcileIdentifier = "com.norte.HealthManager.bgreconcile"

    private let syncEngine: SyncEngine
    private var launchHandlerRegistrationResult: Bool?
    private var isAutomaticSyncReady = false

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    /// Call from App init (before scene becomes active).
    @discardableResult
    func registerLaunchHandlers() -> Bool {
        if let launchHandlerRegistrationResult {
            return launchHandlerRegistrationResult
        }

        let incrementalRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.incrementalIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self, let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleIncremental(task: refreshTask)
            }
        }
        let reconcileRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.reconcileIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor [weak self] in
                guard let self, let processingTask = task as? BGProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handleReconcile(task: processingTask)
            }
        }
        let succeeded = incrementalRegistered && reconcileRegistered
        launchHandlerRegistrationResult = succeeded
        if succeeded {
            AppLogger.shared.bg.info("BGTaskScheduler handlers registered")
        } else {
            AppLogger.shared.bg.error(
                "BGTaskScheduler handler registration incomplete: incremental=\(incrementalRegistered, privacy: .public), reconcile=\(reconcileRegistered, privacy: .public)"
            )
        }
        return succeeded
    }

    /// Opens automatic scheduling and execution only after durable startup recovery succeeds.
    func enableAutomaticSyncAfterRecovery() {
        isAutomaticSyncReady = true
    }

    func scheduleIncrementalIfNeeded() {
        guard isAutomaticSyncReady else {
            AppLogger.shared.bg.warning("Incremental BG scheduling blocked: startup recovery incomplete")
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: Self.incrementalIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)  // ≥ 1h
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.bg.info("Scheduled incremental BG task")
        } catch {
            AppLogger.shared.bg.error("Schedule incremental failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func scheduleReconcileIfNeeded() {
        guard isAutomaticSyncReady else {
            AppLogger.shared.bg.warning("Reconcile BG scheduling blocked: startup recovery incomplete")
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.reconcileIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60 * 6)  // ≥ 6h
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.bg.info("Scheduled reconcile BG task")
        } catch {
            AppLogger.shared.bg.error("Schedule reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Handlers

    private func handleIncremental(task: BGAppRefreshTask) {
        guard isAutomaticSyncReady else {
            AppLogger.shared.bg.error("Incremental BG task rejected: startup recovery incomplete")
            task.setTaskCompleted(success: false)
            return
        }
        scheduleIncrementalIfNeeded() // always reschedule next slot first

        let completionGate = SyncCompletionGate { success in
            task.setTaskCompleted(success: success)
        }
        let work = Task { @MainActor in
            await self.syncEngine.runIncremental(trigger: .bgTask)
            let workStore = SyncWorkStore(database: self.syncEngine.database)
            let assessments = HealthKitTypeCatalog.allReadSampleTypes.map {
                SyncDeliveryAssessment.assess(try? workStore.work(for: $0.identifier))
            }
            let succeeded = !Task.isCancelled
                && !assessments.isEmpty
                && assessments.allSatisfy(\.backgroundSucceeded)
            _ = completionGate.finish(success: succeeded)
        }

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Incremental BG task expired — cancelling sync")
            work.cancel()
            _ = completionGate.finish(success: false)
        }
    }

    private func handleReconcile(task: BGProcessingTask) {
        guard isAutomaticSyncReady else {
            AppLogger.shared.bg.error("Reconcile BG task rejected: startup recovery incomplete")
            task.setTaskCompleted(success: false)
            return
        }
        scheduleReconcileIfNeeded()

        let completionGate = SyncCompletionGate { success in
            task.setTaskCompleted(success: success)
        }
        let work = Task { @MainActor in
            await self.syncEngine.runReconcile(trigger: .bgTask)
            _ = completionGate.finish(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Reconcile BG task expired — cancelling")
            work.cancel()
            _ = completionGate.finish(success: false)
        }
    }
}
