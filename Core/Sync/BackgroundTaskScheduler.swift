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

        let work = Task { @MainActor in
            await self.syncEngine.runIncremental(trigger: .bgTask)
            // If the system already called expirationHandler, this is a no-op (Apple's
            // documented contract); otherwise it tells the system we're done.
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Incremental BG task expired — cancelling sync")
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func handleReconcile(task: BGProcessingTask) {
        scheduleReconcileIfNeeded()

        let work = Task { @MainActor in
            await self.syncEngine.runReconcile(trigger: .bgTask)
            if !Task.isCancelled {
                task.setTaskCompleted(success: true)
            }
        }

        task.expirationHandler = {
            AppLogger.shared.bg.warning("Reconcile BG task expired — cancelling")
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
