import Foundation
import BackgroundTasks
import UIKit

/// BGTask wiring. The actual incremental work is delegated to `SyncEngine.runIncremental`.
/// Round 1 only registers + reschedules; the worker body fills in during Round 3.
final class BackgroundTaskScheduler {

    static let incrementalIdentifier = "com.norte.HealthManager.bgsync"
    static let reconcileIdentifier = "com.norte.HealthManager.bgreconcile"

    private let syncEngine: SyncEngine

    init(syncEngine: SyncEngine) {
        self.syncEngine = syncEngine
    }

    /// Call from App init (before scene becomes active).
    func registerLaunchHandlers() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.incrementalIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleIncremental(task: task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.reconcileIdentifier,
            using: nil
        ) { [weak self] task in
            self?.handleReconcile(task: task as! BGProcessingTask)
        }
        AppLogger.shared.bg.info("BGTaskScheduler handlers registered")
    }

    func scheduleIncrementalIfNeeded() {
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
        scheduleIncrementalIfNeeded() // always reschedule next slot first

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Incremental BG task expired")
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor in
            await self.syncEngine.runIncremental(trigger: .bgTask)
            task.setTaskCompleted(success: true)
        }
    }

    private func handleReconcile(task: BGProcessingTask) {
        scheduleReconcileIfNeeded()

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Reconcile BG task expired")
            task.setTaskCompleted(success: false)
        }

        // Reconcile body filled in Round 6.
        AppLogger.shared.bg.info("handleReconcile: stub — to be implemented in Round 6")
        task.setTaskCompleted(success: true)
    }
}
