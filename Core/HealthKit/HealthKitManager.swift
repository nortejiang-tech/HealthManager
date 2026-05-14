import Foundation
import HealthKit
import Combine

/// Owns the single `HKHealthStore` and exposes authorization + query primitives
/// used by `BackfillCoordinator` and `IncrementalSyncCoordinator`.
///
/// State model:
/// - `authorizationGate` is what UI binds to. It collapses Apple's read-side uncertainty
///   into a small enum that drives onboarding vs main tab.
/// - Apple does NOT report read-permission status. We persist a "已请求过授权" flag and
///   treat the system's `getRequestStatusForAuthorization` as authoritative for re-prompt.
@MainActor
final class HealthKitManager: ObservableObject {

    enum AuthorizationGate: Equatable {
        case unknown
        case needsRequest
        case partiallyGranted
        case granted
        case denied
    }

    enum HKError: LocalizedError {
        case healthDataUnavailable
        case typeUnavailable(String)
        case queryFailed(underlying: Error)
        case authorizationDenied

        var errorDescription: String? {
            switch self {
            case .healthDataUnavailable: return "本机不支持 HealthKit。"
            case .typeUnavailable(let id): return "HealthKit 类型不可用：\(id)"
            case .queryFailed(let err): return "HealthKit 查询失败：\(err.localizedDescription)"
            case .authorizationDenied: return "HealthKit 授权被拒绝。"
            }
        }
    }

    @Published private(set) var authorizationGate: AuthorizationGate = .unknown
    @Published private(set) var lastAuthorizationError: String?

    let store = HKHealthStore()
    private let database: DatabaseManager
    private let defaults: UserDefaults
    private let hasRequestedKey = "hk.hasRequestedAuthorization"

    init(database: DatabaseManager, defaults: UserDefaults = .standard) {
        self.database = database
        self.defaults = defaults
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    var hasRequestedAuthorization: Bool {
        get { defaults.bool(forKey: hasRequestedKey) }
        set { defaults.set(newValue, forKey: hasRequestedKey) }
    }

    // MARK: - Authorization

    /// Recomputes the gate from system state. Safe to call on app launch and on resume.
    func refreshAuthorizationGate() async {
        #if DEBUG
        // Smoke-test bypass: lets the simulator preview render past onboarding when
        // HealthKit data isn't really available. Wired via launch arg from tooling.
        if ProcessInfo.processInfo.arguments.contains("-HM_DEBUG_BYPASS_ONBOARDING") {
            authorizationGate = .partiallyGranted
            return
        }
        #endif
        guard isAvailable else {
            authorizationGate = .denied
            return
        }
        let readTypes = HealthKitTypeCatalog.allReadObjectTypes
        do {
            let status = try await store.statusForAuthorizationRequest(
                toShare: HealthKitTypeCatalog.writeSampleTypes,
                read: readTypes
            )
            switch status {
            case .shouldRequest:
                authorizationGate = hasRequestedAuthorization ? .partiallyGranted : .needsRequest
            case .unnecessary:
                authorizationGate = .granted
            case .unknown:
                authorizationGate = .unknown
            @unknown default:
                authorizationGate = .unknown
            }
        } catch {
            AppLogger.shared.error("statusForAuthorizationRequest failed: \(error)")
            authorizationGate = .unknown
        }
    }

    /// Presents the system permission sheet. Returns once user dismisses it.
    /// Note: Apple does not surface which read types were granted; we set the flag and
    /// assume the user made an informed choice.
    func requestAuthorization() async throws {
        guard isAvailable else { throw HKError.healthDataUnavailable }
        do {
            try await store.requestAuthorization(
                toShare: HealthKitTypeCatalog.writeSampleTypes,
                read: HealthKitTypeCatalog.allReadObjectTypes
            )
            hasRequestedAuthorization = true
            lastAuthorizationError = nil
            await refreshAuthorizationGate()
        } catch {
            lastAuthorizationError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Query primitives

    /// Bounded historical fetch. Used by Backfill (default 30 days).
    nonisolated func fetchSamples(
        for sampleType: HKSampleType,
        from startDate: Date,
        to endDate: Date,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKSample], Error>) in
            let predicate = HKQuery.predicateForSamples(
                withStart: startDate,
                end: endDate,
                options: [.strictStartDate]
            )
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    cont.resume(throwing: HKError.queryFailed(underlying: error))
                } else {
                    cont.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    /// Anchored fetch — used by IncrementalSync to pull only what's new since the last anchor.
    /// Returns added samples, tombstones, and the new anchor (caller must persist it).
    struct AnchoredResult {
        let added: [HKSample]
        let deleted: [HKDeletedObject]
        let newAnchor: HKQueryAnchor?
    }

    nonisolated func anchoredFetch(
        for sampleType: HKSampleType,
        anchor: HKQueryAnchor?,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> AnchoredResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AnchoredResult, Error>) in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    cont.resume(throwing: HKError.queryFailed(underlying: error))
                } else {
                    cont.resume(returning: AnchoredResult(
                        added: samples ?? [],
                        deleted: deleted ?? [],
                        newAnchor: newAnchor
                    ))
                }
            }
            store.execute(query)
        }
    }
}
