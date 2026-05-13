import Foundation
import Combine

/// Public surface for triggering syncs. UI calls into this; coordinators do the work.
///
/// V1 wiring (Round 1):
/// - `runBackfill` is real (delegates to BackfillCoordinator).
/// - `runIncremental` / `runManualSync` are stubs that will be filled in Rounds 3/4.
@MainActor
final class SyncEngine: ObservableObject {

    struct LastResult: Equatable {
        let jobId: Int64
        let jobType: SyncJob.JobType
        let succeeded: Bool
        let startedAt: Date
        let endedAt: Date
        let totalSamples: Int
        let perTypeCounts: [String: Int]
        let errorMessage: String?
    }

    @Published private(set) var phase: SyncStateMachine.Phase = .idle
    @Published private(set) var lastResult: LastResult?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var progressDescription: String = ""

    let database: DatabaseManager
    let healthKitManager: HealthKitManager
    private(set) lazy var backfillCoordinator = BackfillCoordinator(
        healthKitManager: healthKitManager,
        database: database
    )

    private var stateMachine = SyncStateMachine()

    init(database: DatabaseManager, healthKitManager: HealthKitManager) {
        self.database = database
        self.healthKitManager = healthKitManager
    }

    // MARK: - Backfill (F-001A)

    func runBackfill(days: Int = 30, trigger: SyncJob.Trigger = .user) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            try stateMachine.handle(.startBackfill)
            phase = stateMachine.phase

            progressDescription = "回补最近 \(days) 天历史数据…"
            let result = try await backfillCoordinator.run(
                days: days,
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                }
            )

            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase
            lastResult = result
            progressDescription = "回补完成：共 \(result.totalSamples) 条样本。"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "回补失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error("Backfill failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Incremental (F-001) — stub for Round 3

    func runIncremental(trigger: SyncJob.Trigger = .timer) async {
        AppLogger.shared.sync.info("runIncremental: stub — to be implemented in Round 3")
    }

    // MARK: - Manual one-shot (F-002) — stub for Round 4

    func runManualSync() async {
        AppLogger.shared.sync.info("runManualSync: stub — to be implemented in Round 4")
    }

    // MARK: - Reset

    func reset() {
        try? stateMachine.handle(.reset)
        phase = stateMachine.phase
        progressDescription = ""
    }
}
