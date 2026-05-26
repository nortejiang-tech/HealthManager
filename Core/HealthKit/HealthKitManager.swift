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

    // MARK: - Nutrition write-back

    /// Metadata key stamped on every dietary sample we write, valued with the meal's
    /// sync id so we can find/replace/delete exactly this app's samples for a meal.
    static let mealSyncIdKey = "HMMealSyncID"

    /// Prompt for dietary share permission only when still undetermined. HealthKit won't
    /// re-show the sheet for types the user already decided on.
    func ensureNutritionWriteAuthorization() async {
        guard isAvailable else { return }
        // Include the food correlation type so users who only granted the nutrient toggles
        // (before grouping existed) get re-prompted to allow saving meals as one entry.
        let needsRequest = HealthKitTypeCatalog.writeSampleTypes.contains {
            store.authorizationStatus(for: $0) == .notDetermined
        }
        guard needsRequest else { return }
        do {
            // Request the macros + the food correlation so we can save grouped meals.
            try await store.requestAuthorization(toShare: HealthKitTypeCatalog.writeSampleTypes, read: [])
        } catch {
            AppLogger.shared.error("Nutrition write authorization failed: \(error.localizedDescription)")
        }
    }

    /// Explicitly (re)request dietary share permission and report whether any dietary type
    /// is authorized afterwards. Drives the Settings "同步到 Apple 健康" button so the user
    /// can grant write access on demand even if they skipped it during onboarding.
    @discardableResult
    func requestNutritionWriteAuthorization() async -> Bool {
        guard isAvailable else { return false }
        let types = HealthKitTypeCatalog.nutritionWriteSampleTypes
        let undetermined = HealthKitTypeCatalog.writeSampleTypes.contains {
            store.authorizationStatus(for: $0) == .notDetermined
        }
        if undetermined {
            do {
                try await store.requestAuthorization(toShare: HealthKitTypeCatalog.writeSampleTypes, read: [])
            } catch {
                AppLogger.shared.error("Nutrition write authorization failed: \(error.localizedDescription)")
            }
        }
        return types.contains { store.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    /// True when at least one dietary write type is authorized — used to show status.
    var isNutritionWriteAuthorized: Bool {
        HealthKitTypeCatalog.nutritionWriteSampleTypes.contains {
            store.authorizationStatus(for: $0) == .sharingAuthorized
        }
    }

    /// Write (or re-write) one meal's macros to Apple Health. Returns the sync id stamped
    /// on the samples (caller persists it on the meal), or the existing id / nil on failure.
    /// Idempotent: if `existingSyncId` is set, its previously-written samples are deleted first.
    func syncMealNutrition(
        eatenAt: Int64,
        calories: Double?, protein: Double?, fat: Double?, carbs: Double?,
        name: String?,
        existingSyncId: String?
    ) async -> String? {
        guard isAvailable else { return existingSyncId }
        await ensureNutritionWriteAuthorization()

        if let old = existingSyncId {
            await deleteNutritionSamples(syncId: old)
        }

        let date = Date(timeIntervalSince1970: TimeInterval(eatenAt))
        let syncId = existingSyncId ?? UUID().uuidString
        let pairs: [(HKQuantityTypeIdentifier, Double?)] = [
            (.dietaryEnergyConsumed, calories),
            (.dietaryProtein, protein),
            (.dietaryFatTotal, fat),
            (.dietaryCarbohydrates, carbs)
        ]
        var samples: [HKQuantitySample] = []
        for (id, value) in pairs {
            guard let value, value > 0,
                  let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            // Skip types the user declined to share — saving them would throw.
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            var metadata: [String: Any] = [
                HKMetadataKeyWasUserEntered: true,
                Self.mealSyncIdKey: syncId
            ]
            if let name, !name.isEmpty { metadata[HKMetadataKeyFoodType] = name }
            let sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: HealthKitTypeCatalog.preferredUnit(for: id), doubleValue: value),
                start: date, end: date,
                metadata: metadata
            )
            samples.append(sample)
        }
        guard !samples.isEmpty else { return existingSyncId }

        // Preferred: bundle the macros into one `.food` correlation so Apple Health shows
        // them as a single meal. Saving only needs the contained nutrient types authorized
        // (the correlation type itself can't be authorization-requested), so we just try it.
        if let foodType = HealthKitTypeCatalog.foodCorrelationType {
            var correlationMeta: [String: Any] = [
                HKMetadataKeyWasUserEntered: true,
                Self.mealSyncIdKey: syncId
            ]
            if let name, !name.isEmpty { correlationMeta[HKMetadataKeyFoodType] = name }
            let correlation = HKCorrelation(
                type: foodType, start: date, end: date,
                objects: Set(samples), metadata: correlationMeta
            )
            do {
                try await store.save(correlation)
                return syncId
            } catch {
                AppLogger.shared.error("Meal correlation write failed, falling back to samples: \(error.localizedDescription)")
                // Fall through to writing the individual samples below.
            }
        }

        // Fallback: write the macros as standalone nutrient samples (still counted in
        // Apple Health's nutrition totals, just not grouped as one meal).
        do {
            try await store.save(samples)
            return syncId
        } catch {
            AppLogger.shared.error("Meal nutrition write failed: \(error.localizedDescription)")
            return existingSyncId
        }
    }

    /// Delete the dietary nutrient samples previously written for `syncId` (app-authored).
    /// Removing the member samples empties any food correlation they belonged to, so the
    /// meal entry clears too — we can't target the correlation type directly because its
    /// share authorization can't be requested.
    func deleteNutritionSamples(syncId: String) async {
        guard isAvailable else { return }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: Self.mealSyncIdKey, allowedValues: [syncId])
        for type in HealthKitTypeCatalog.nutritionWriteSampleTypes {
            guard store.authorizationStatus(for: type) == .sharingAuthorized else { continue }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                    if let error {
                        AppLogger.shared.error("Meal nutrition delete failed: \(error.localizedDescription)")
                    }
                    cont.resume()
                }
            }
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

    struct DailyCumulativeStatistic: Sendable {
        let startDate: Date
        let value: Double?
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

    /// HealthKit's own daily cumulative projection. Use this for metrics where matching
    /// Apple Health's day total matters more than source-level attribution, especially steps.
    nonisolated func fetchDailyCumulativeStatistics(
        for identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [DailyCumulativeStatistic] {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
            throw HKError.typeUnavailable(identifier.rawValue)
        }

        let calendar = Calendar.current
        let anchorDate = calendar.startOfDay(for: startDate)
        var interval = DateComponents()
        interval.day = 1
        let predicate = HKQuery.predicateForSamples(withStart: anchorDate, end: endDate)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[DailyCumulativeStatistic], Error>) in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: [.cumulativeSum],
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, collection, error in
                if let error {
                    cont.resume(throwing: HKError.queryFailed(underlying: error))
                    return
                }
                guard let collection else {
                    cont.resume(returning: [])
                    return
                }

                var output: [DailyCumulativeStatistic] = []
                collection.enumerateStatistics(from: anchorDate, to: endDate) { stats, _ in
                    output.append(DailyCumulativeStatistic(
                        startDate: stats.startDate,
                        value: stats.sumQuantity()?.doubleValue(for: unit)
                    ))
                }
                cont.resume(returning: output)
            }
            store.execute(query)
        }
    }
}
