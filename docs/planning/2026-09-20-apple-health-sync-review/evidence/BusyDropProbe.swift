import Foundation

/// PRD §5 state machine. Kept in a separate type so each phase has a single source of truth
/// and unit-testable transitions.
struct SyncStateMachine {

    enum Phase: Equatable {
        case idle
        case requestingAuth
        case backfilling
        case syncingIncremental
        case waitingExternalSync
        case syncingIncremental2
        case reconciling
        case completed
        case failed
    }

    enum Event {
        case startBackfill
        case startIncremental
        case startManual
        case authRequested
        case incrementalFinished
        case userPromptedForExternal
        case userResumedFromExternal
        case reconcileFinished
        case fail
        case reset
    }

    enum TransitionError: Error {
        case invalidTransition(from: Phase, event: Event)
    }

    private(set) var phase: Phase = .idle

    mutating func handle(_ event: Event) throws {
        switch (phase, event) {
        case (.idle, .startBackfill): phase = .backfilling
        case (.backfilling, .reconcileFinished): phase = .completed
        case (.backfilling, .fail): phase = .failed

        case (.idle, .startIncremental): phase = .syncingIncremental
        case (.syncingIncremental, .incrementalFinished): phase = .reconciling
        case (.reconciling, .reconcileFinished): phase = .completed
        case (.syncingIncremental, .fail), (.reconciling, .fail): phase = .failed

        case (.idle, .startManual): phase = .syncingIncremental
        case (.syncingIncremental, .userPromptedForExternal): phase = .waitingExternalSync
        case (.waitingExternalSync, .userResumedFromExternal): phase = .syncingIncremental2
        case (.syncingIncremental2, .incrementalFinished): phase = .reconciling

        case (.idle, .authRequested): phase = .requestingAuth
        case (.requestingAuth, .startBackfill): phase = .backfilling

        case (_, .reset): phase = .idle

        default:
            throw TransitionError.invalidTransition(from: phase, event: event)
        }
    }

    var isTerminal: Bool { phase == .completed || phase == .failed }
}


import Foundation
import Darwin
enum MockPrivacy { case `public` }
extension String.StringInterpolation {
 mutating func appendInterpolation(_ value: String, privacy: MockPrivacy) { appendLiteral(value) }
}
struct MockLog { func info(_ s: String) {} ; func error(_ s: String) {} }
struct AppLogger { static let shared = AppLogger(); let sync = MockLog() }
enum SyncJob { enum Trigger { case timer, observer } }
struct Result { let succeeded: Bool; let totalSamples: Int; let errorMessage: String? }
@MainActor final class ControlledCoordinator {
 var passes = 0
 var sourceVersion = 0
 var importedVersion = -1
 var firstParked: CheckedContinuation<Void,Never>?
 func run(trigger: SyncJob.Trigger, progress: @escaping (String)->Void) async throws -> Result {
  passes += 1
  let captured = sourceVersion
  if passes == 1 { await withCheckedContinuation { firstParked = $0 } }
  importedVersion = captured
  return Result(succeeded: true, totalSamples: 1, errorMessage: nil)
 }
}
@MainActor final class EngineProbe {
 var isBusy = false
 var stateMachine = SyncStateMachine()
 var phase: SyncStateMachine.Phase = .idle
 var progressDescription = ""
 var lastResult: Result?
 var onDataSynchronized: (@MainActor () async -> Void)?
 let incrementalCoordinator = ControlledCoordinator()
 func requireStartupRecoveryReady(operation: String) -> Bool { true }
 func rebuildDailyProjections(daysBack: Int) async {}
 func pushMealNutritionToHealth(requestAuthIfNeeded: Bool) async {}
    func runIncremental(trigger: SyncJob.Trigger = .timer) async {
        guard requireStartupRecoveryReady(operation: "增量同步") else { return }
        // Single-flight: observer / BG task / timer can all converge here in quick succession.
        // Dropping concurrent calls is safe — whoever wins picks up everything new since the
        // last anchor on the next pass.
        guard !isBusy else {
            AppLogger.shared.sync.info("runIncremental skipped: busy")
            return
        }
        isBusy = true
        defer {
            isBusy = false
            Task { await onDataSynchronized?() }
        }

        do {
            try? stateMachine.handle(.reset)
            try stateMachine.handle(.startIncremental)
            phase = stateMachine.phase
            progressDescription = "增量同步中…"

            let result = try await incrementalCoordinator.run(
                trigger: trigger,
                progress: { [weak self] desc in
                    Task { @MainActor in self?.progressDescription = desc }
                }
            )

            try stateMachine.handle(.incrementalFinished)
            phase = stateMachine.phase
            try stateMachine.handle(.reconcileFinished)
            phase = stateMachine.phase

            lastResult = result
            await rebuildDailyProjections(daysBack: 7)
            // Silent catch-up: write any not-yet-synced meal nutrition into Apple Health.
            await pushMealNutritionToHealth(requestAuthIfNeeded: false)
            progressDescription = result.succeeded
                ? "增量同步完成：本轮新增 \(result.totalSamples) 条。"
                : "增量同步失败：\(result.errorMessage ?? "未知错误")"
        } catch {
            try? stateMachine.handle(.fail)
            phase = stateMachine.phase
            progressDescription = "增量同步失败：\(error.localizedDescription)"
            AppLogger.shared.sync.error(
                "runIncremental failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }


}
@main struct Main {
 @MainActor static func main() async {
  let engine = EngineProbe()
  let first = Task { await engine.runIncremental(trigger: .timer) }
  while engine.incrementalCoordinator.firstParked == nil { await Task.yield() }
  // HealthKit receives a write AFTER the running pass has captured this type.
  engine.incrementalCoordinator.sourceVersion = 1
  // Exactly the real observer call site: await runIncremental, then acknowledge.
  await engine.runIncremental(trigger: .observer)
  let observerAcknowledged = true
  engine.incrementalCoordinator.firstParked?.resume()
  await first.value
  for _ in 0..<100 { await Task.yield() }
  let c = engine.incrementalCoordinator
  print("passes=\(c.passes), sourceVersion=\(c.sourceVersion), importedVersion=\(c.importedVersion), observerAcknowledged=\(observerAcknowledged), isBusy=\(engine.isBusy)")
  if c.importedVersion != c.sourceVersion {
   print("FAIL: observer event acknowledged but new data not imported; no follow-up pass scheduled")
   exit(1)
  }
  print("PASS: data caught up automatically")
 }
}
