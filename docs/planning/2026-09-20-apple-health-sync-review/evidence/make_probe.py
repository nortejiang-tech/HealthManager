from pathlib import Path
import hashlib,json
root=Path('/Users/nortepro/HealthManager')
out=Path('/tmp/healthmanager-sync-audit-20260920.N3V3Ua')
s=(root/'Core/Sync/SyncEngine.swift').read_text()
method=s[s.index('    func runIncremental('):s.index('    // MARK: - Manual')]
state=(root/'Core/Sync/SyncStateMachine.swift').read_text()
prefix=r'''
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
'''
suffix=r'''
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
'''
(out/'BusyDropProbe.swift').write_text(state+'\n'+prefix+method+suffix)
(out/'probe-source.json').write_text(json.dumps({'source':'Core/Sync/SyncEngine.swift','method':'runIncremental','method_sha256':hashlib.sha256(method.encode()).hexdigest(),'boundary':'Production method extracted verbatim; HealthKit, DB, aggregation and lifecycle use controlled doubles. Tests request scheduling only, not device HealthKit delivery.'},indent=2))
