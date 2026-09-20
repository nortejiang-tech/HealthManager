import Foundation
import HealthKit

enum SyncDeliveryAssessment: Equatable {
    case applied
    case deferred(SyncDeferredReason)
    case failed(SyncDeferredReason?)
    case notPersisted

    static func assess(_ work: SyncTypeWork?) -> SyncDeliveryAssessment {
        guard let work else { return .notPersisted }
        if !work.isPending { return .applied }
        guard let reason = work.deferredReason else { return .failed(nil) }
        switch reason {
        case .waitForUnlock, .authorizationCheck, .cancelled, .transient:
            return .deferred(reason)
        case .repairRequired, .failure:
            return .failed(reason)
        }
    }

    var observerMayAcknowledge: Bool {
        switch self {
        case .applied, .deferred: return true
        case .failed, .notPersisted: return false
        }
    }

    var backgroundSucceeded: Bool {
        self == .applied
    }
}

final class SyncCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (Bool) -> Void

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(success: Bool) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        completion(success)
        return true
    }
}

struct BackgroundDeliveryRetryPolicy {
    static let maximumAttempts = 3

    static func delay(afterFailedAttempt attempt: Int) -> TimeInterval? {
        guard attempt > 0, attempt < maximumAttempts else { return nil }
        return 30 * pow(2, Double(attempt - 1))
    }
}

/// Maps one HealthKit observer delivery to the *exact* durable demand scope for that callback.
///
/// Design §5: observer only marks its own type; foreground/auth/unlock/background/manual are
/// the opportunities allowed to request the whole catalog. Without this scoping every delivery
/// bumped `requested_generation` for all 28 catalog types, so a single activation produced ~28
/// full-catalog passes and types with no new samples stayed pending forever.
enum HealthKitObserverDemand {
    /// One-element scope carrying exactly the delivered type identifier.
    static func scope(identifier: String) -> Set<String> {
        [identifier]
    }
}

struct HealthKitObserverInitialDeliveryCoverage {
    private(set) var identifiers: Set<String> = []

    mutating func mark(_ identifier: String) {
        identifiers.insert(identifier)
    }

    mutating func consume(_ identifier: String) -> Bool {
        identifiers.remove(identifier) != nil
    }

    mutating func reset() {
        identifiers.removeAll()
    }
}

/// Owns one observer query per catalog type and adapts each HealthKit delivery into durable
/// runner demand. The system completion is acknowledged only after work applied or was safely
/// handed off to a resumable deferred ledger state.
@MainActor
final class HealthKitObserver {
    private let healthKitManager: HealthKitManager
    private let syncEngine: SyncEngine
    private let workStore: SyncWorkStore
    private var activeQueriesByType: [String: HKObserverQuery] = [:]
    private var backgroundDeliveryReady: Set<String> = []
    private var backgroundDeliveryAttempts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var initialDeliveryCoverage = HealthKitObserverInitialDeliveryCoverage()

    init(healthKitManager: HealthKitManager, syncEngine: SyncEngine) {
        self.healthKitManager = healthKitManager
        self.syncEngine = syncEngine
        self.workStore = SyncWorkStore(database: syncEngine.database)
    }

    /// Idempotently registers missing queries and retries only background-delivery types that
    /// have not yet succeeded. A prior enable failure no longer permanently closes retry.
    func start(initialDeliveryCoveredByImmediateFullCheck: Bool = false) {
        guard healthKitManager.isAvailable else {
            AppLogger.shared.healthkit.info("HealthKitObserver.start skipped: HK unavailable")
            return
        }
        for sampleType in HealthKitTypeCatalog.allReadSampleTypes {
            registerQueryIfNeeded(
                for: sampleType,
                initialDeliveryCoveredByImmediateFullCheck: initialDeliveryCoveredByImmediateFullCheck
            )
            enableBackgroundDeliveryIfNeeded(for: sampleType)
        }
        AppLogger.shared.healthkit.info(
            "HealthKitObserver active queries=\(self.activeQueriesByType.count), deliveryReady=\(self.backgroundDeliveryReady.count)"
        )
    }

    func stop() {
        let store = healthKitManager.store
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        for query in activeQueriesByType.values { store.stop(query) }
        activeQueriesByType.removeAll()
        backgroundDeliveryReady.removeAll()
        backgroundDeliveryAttempts.removeAll()
        initialDeliveryCoverage.reset()
        store.disableAllBackgroundDelivery { _, error in
            if let error {
                AppLogger.shared.healthkit.error(
                    "disableAllBackgroundDelivery failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func registerQueryIfNeeded(
        for sampleType: HKSampleType,
        initialDeliveryCoveredByImmediateFullCheck: Bool
    ) {
        let identifier = sampleType.identifier
        guard activeQueriesByType[identifier] == nil else { return }
        if initialDeliveryCoveredByImmediateFullCheck {
            initialDeliveryCoverage.mark(identifier)
        }
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error {
                AppLogger.shared.healthkit.error(
                    "Observer fired with error for \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    _ = self?.initialDeliveryCoverage.consume(identifier)
                    completionHandler()
                }
                return
            }
            let gate = SyncCompletionGate { _ in completionHandler() }
            let demandScope = HealthKitObserverDemand.scope(identifier: identifier)
            Task { @MainActor [weak self] in
                guard let self else {
                    _ = gate.finish(success: false)
                    return
                }
                if self.initialDeliveryCoverage.consume(identifier) {
                    // Registration's first observer delivery is covered by the full-type check
                    // scheduled in the same startup action batch. That check begins after all
                    // queries are registered, so it also includes writes racing registration.
                    _ = gate.finish(success: true)
                    return
                }
                await self.syncEngine.runIncremental(
                    trigger: .observer,
                    typeScope: demandScope
                )
                let assessment = SyncDeliveryAssessment.assess(
                    try? self.workStore.work(for: identifier)
                )
                if assessment.observerMayAcknowledge {
                    _ = gate.finish(success: true)
                    if case .deferred(let reason) = assessment {
                        AppLogger.shared.healthkit.info(
                            "Observer delivery durably deferred for \(identifier, privacy: .public): \(reason.rawValue, privacy: .public)"
                        )
                    }
                } else {
                    AppLogger.shared.healthkit.error(
                        "Observer delivery not acknowledged; durable handoff failed for \(identifier, privacy: .public)"
                    )
                }
            }
        }
        healthKitManager.store.execute(query)
        activeQueriesByType[identifier] = query
    }

    private func enableBackgroundDeliveryIfNeeded(for sampleType: HKSampleType) {
        let identifier = sampleType.identifier
        guard !backgroundDeliveryReady.contains(identifier), retryTasks[identifier] == nil else { return }
        backgroundDeliveryAttempts[identifier, default: 0] += 1
        let attempt = backgroundDeliveryAttempts[identifier, default: 1]
        healthKitManager.store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success, error == nil {
                    self.backgroundDeliveryReady.insert(identifier)
                    self.backgroundDeliveryAttempts[identifier] = 0
                    return
                }
                AppLogger.shared.healthkit.error(
                    "enableBackgroundDelivery failed for \(identifier, privacy: .public), attempt=\(attempt): \(error?.localizedDescription ?? "returned false", privacy: .public)"
                )
                guard let delay = BackgroundDeliveryRetryPolicy.delay(afterFailedAttempt: attempt) else { return }
                self.retryTasks[identifier] = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.retryTasks[identifier] = nil
                    self.enableBackgroundDeliveryIfNeeded(for: sampleType)
                }
            }
        }
    }
}
