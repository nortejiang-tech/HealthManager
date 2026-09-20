import Foundation
import HealthKit
import GRDB

enum IncrementalSyncCoordinatorError: LocalizedError, Equatable {
    case unknownPersistedType(String)

    var errorDescription: String? {
        switch self {
        case .unknownPersistedType(let identifier):
            return "持久同步类型不在当前 HealthKit 目录中：\(identifier)"
        }
    }
}

/// Compatibility coordinator over the durable, paged sync path.
///
/// Entry points request generations in `SyncWorkStore`; every type then runs a bounded page
/// slice. S08 replaces the compatibility loop with the single shared `SyncRunner`, while this
/// stage already removes unlimited HealthKit reads and split row/anchor transactions.
actor IncrementalSyncCoordinator {
    private let healthKitManager: HealthKitManager
    private let database: DatabaseManager
    private let workStore: SyncWorkStore
    private let maximumPagesPerType: Int
    private let sliceDuration: TimeInterval

    init(
        healthKitManager: HealthKitManager,
        database: DatabaseManager,
        maxAttempts: Int = 3,
        maximumPagesPerType: Int = 8,
        sliceDuration: TimeInterval = 8
    ) {
        self.healthKitManager = healthKitManager
        self.database = database
        self.workStore = SyncWorkStore(database: database)
        self.maximumPagesPerType = maximumPagesPerType
        self.sliceDuration = sliceDuration
        _ = maxAttempts // Kept for source compatibility; retries belong to the shared runner.
    }

    struct TypeOutcome {
        let identifier: String
        let added: Int
        let deleted: Int
        let pages: Int
        let hasPending: Bool
        let error: Error?
        let failedStage: SyncStage?
    }

    struct PassResult {
        var perTypeCounts: [String: Int]
        var firstError: Error?
        var errors: [SyncTypeError]
        var hasPending: Bool
    }

    struct ReadyTypeSelection {
        let sampleTypes: [HKSampleType]
        let unknownIdentifiers: [String]
    }

    func run(
        trigger: SyncJob.Trigger,
        progress: @escaping (String) -> Void
    ) async throws -> SyncEngine.LastResult {
        let jobStart = Date()
        let jobId = try SyncJobRecorder(database: database).openJob(
            jobType: .incremental,
            trigger: trigger,
            startedAt: jobStart
        )
        let pass = await executePass(progress: progress)
        let endedAt = Date()
        let totalSamples = pass.perTypeCounts.values.reduce(0, +)
        let succeeded = pass.firstError == nil
        try SyncJobRecorder(database: database).closeJob(
            id: jobId,
            endedAt: endedAt,
            succeeded: succeeded,
            errorMessage: pass.firstError?.localizedDescription,
            stats: pass.perTypeCounts
        )
        return SyncEngine.LastResult(
            jobId: jobId,
            jobType: .incremental,
            succeeded: succeeded,
            startedAt: jobStart,
            endedAt: endedAt,
            totalSamples: totalSamples,
            perTypeCounts: pass.perTypeCounts,
            perTypeErrors: pass.errors,
            errorMessage: pass.firstError?.localizedDescription
        )
    }

    func executePass(progress: @escaping (String) -> Void) async -> PassResult {
        let readyWork: [SyncTypeWork]
        do {
            readyWork = try workStore.pendingWork()
        } catch {
            return PassResult(perTypeCounts: [:], firstError: error, errors: [], hasPending: true)
        }
        let selection = Self.selectReadyTypes(
            from: readyWork,
            catalog: HealthKitTypeCatalog.allReadSampleTypes
        )
        let sampleTypes = selection.sampleTypes

        var counts: [String: Int] = [:]
        var firstError: Error?
        var errors: [SyncTypeError] = []
        var hasPending = false

        for identifier in selection.unknownIdentifiers {
            let error = IncrementalSyncCoordinatorError.unknownPersistedType(identifier)
            deferUnknownType(identifier, error: error)
            errors.append(SyncTypeError(
                hkType: identifier,
                stage: .loadAnchor,
                underlying: error.localizedDescription,
                isAuthDenied: false,
                occurredAt: Date()
            ))
            if firstError == nil { firstError = error }
            hasPending = true
            AppLogger.shared.sync.error(
                "Incremental persisted unknown type deferred for repair: \(identifier, privacy: .public)"
            )
        }

        for (index, sampleType) in sampleTypes.enumerated() {
            let identifier = sampleType.identifier
            progress("[\(index + 1)/\(sampleTypes.count)] 增量同步 \(identifier)…")
            let outcome = await syncType(sampleType, identifier: identifier)
            counts[identifier] = outcome.added
            hasPending = hasPending || outcome.hasPending

            if let error = outcome.error {
                let authDenied = SyncTypeError.isAuthorizationDenied(error)
                errors.append(SyncTypeError(
                    hkType: identifier,
                    stage: outcome.failedStage ?? .hkQuery,
                    underlying: error.localizedDescription,
                    isAuthDenied: authDenied,
                    occurredAt: Date()
                ))
                if !authDenied, firstError == nil { firstError = error }
                AppLogger.shared.sync.error(
                    "Incremental \(identifier, privacy: .public) failed at \(outcome.failedStage?.rawValue ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if Self.shouldDeferRemainingTypes(after: error) {
                    let remaining = sampleTypes.dropFirst(index + 1).map(\.identifier)
                    deferUnqueriedTypes(remaining, reason: .waitForUnlock)
                    hasPending = true
                    AppLogger.shared.sync.info(
                        "HealthKit protected data unavailable; deferred \(remaining.count) unqueried types"
                    )
                    break
                }
            } else {
                AppLogger.shared.sync.info(
                    "Incremental \(identifier, privacy: .public): pages=\(outcome.pages) +\(outcome.added) / -\(outcome.deleted), pending=\(outcome.hasPending)"
                )
            }
        }

        return PassResult(
            perTypeCounts: counts,
            firstError: firstError,
            errors: errors,
            hasPending: hasPending
        )
    }

    /// Select only durable ready work, while preserving the catalog's stable query order.
    /// Unknown persisted identifiers are returned separately so the caller can defer them once
    /// instead of spinning a worker that can never construct an HKSampleType.
    static func selectReadyTypes(
        from work: [SyncTypeWork],
        catalog: [HKSampleType]
    ) -> ReadyTypeSelection {
        let readyIdentifiers = Set(work.lazy.filter(\.isPending).map(\.hkType))
        let knownIdentifiers = Set(catalog.map(\.identifier))
        return ReadyTypeSelection(
            sampleTypes: catalog.filter { readyIdentifiers.contains($0.identifier) },
            unknownIdentifiers: readyIdentifiers.subtracting(knownIdentifiers).sorted()
        )
    }

    private func syncType(_ sampleType: HKSampleType, identifier: String) async -> TypeOutcome {
        do {
            guard let claim = try workStore.claim(type: identifier, token: UUID()) else {
                return TypeOutcome(
                    identifier: identifier,
                    added: 0,
                    deleted: 0,
                    pages: 0,
                    hasPending: (try workStore.work(for: identifier)?.isPending) ?? false,
                    error: nil,
                    failedStage: nil
                )
            }

            let anchorData = try loadAnchorData(for: identifier)
            _ = try Self.decodeAnchor(anchorData, type: identifier)
            let runner = SyncPageRunner(workStore: workStore)
            let result = try await runner.run(
                claim: claim,
                initialAnchorData: anchorData,
                budget: SyncPageBudget(
                    maximumPages: maximumPagesPerType,
                    deadline: Date().addingTimeInterval(sliceDuration)
                )
            ) { [healthKitManager] currentAnchorData, limit in
                let anchor = try Self.decodeAnchor(currentAnchorData, type: identifier)
                let fetched = try await healthKitManager.anchoredFetch(
                    for: sampleType,
                    anchor: anchor,
                    limit: limit
                )
                let ingestedAt = Date()
                var rows: [HealthSampleRaw] = []
                rows.reserveCapacity(fetched.added.count)
                for sample in fetched.added {
                    guard let row = SampleMapper.map(sample, ingestedAt: ingestedAt) else {
                        throw SyncPageRunnerError.mappingFailed(
                            type: identifier,
                            sampleID: sample.uuid.uuidString
                        )
                    }
                    rows.append(row)
                }
                let archivedAnchor = try fetched.newAnchor.map(Self.archiveAnchor)
                return SyncFetchedPage(
                    addedRows: rows,
                    deletedUUIDs: fetched.deleted.map { $0.uuid.uuidString },
                    newAnchorData: archivedAnchor
                )
            }
            return TypeOutcome(
                identifier: identifier,
                added: result.actualInserted,
                deleted: result.actualDeleted,
                pages: result.pagesCommitted,
                hasPending: result.state == .hasPending,
                error: nil,
                failedStage: nil
            )
        } catch {
            await deferFailedType(identifier: identifier, error: error)
            return TypeOutcome(
                identifier: identifier,
                added: 0,
                deleted: 0,
                pages: 0,
                hasPending: true,
                error: error,
                failedStage: Self.stage(for: error)
            )
        }
    }

    private func deferFailedType(identifier: String, error: Error) async {
        guard let claim = try? workStore.claim(type: identifier, token: UUID()) else { return }
        let reason: SyncDeferredReason
        if case SyncPageRunnerError.repairRequired = error {
            reason = .repairRequired
        } else {
            switch SyncFailurePolicy.classify(error) {
            case .waitForUnlock: reason = .waitForUnlock
            case .authorizationCheck: reason = .authorizationCheck
            case .cancelled: reason = .cancelled
            case .transient: reason = .transient
            case .repairRequired: reason = .repairRequired
            case .failure, .unknown: reason = .failure
            }
        }
        try? workStore.deferClaim(
            claim,
            reason: reason,
            retryAt: nil,
            errorCode: String(describing: error)
        )
    }

    private func deferUnknownType(_ identifier: String, error: Error) {
        guard let claim = try? workStore.claim(type: identifier, token: UUID()) else { return }
        try? workStore.deferClaim(
            claim,
            reason: .repairRequired,
            retryAt: nil,
            errorCode: String(describing: error)
        )
    }

    private func deferUnqueriedTypes(_ identifiers: [String], reason: SyncDeferredReason) {
        for identifier in identifiers {
            guard let claim = try? workStore.claim(type: identifier, token: UUID()) else { continue }
            try? workStore.deferClaim(
                claim,
                reason: reason,
                retryAt: nil,
                errorCode: "protected_data_unavailable"
            )
        }
    }

    private func loadAnchorData(for identifier: String) throws -> Data? {
        try database.read { db in
            try Data.fetchOne(
                db,
                sql: "SELECT anchor_data FROM sync_anchors WHERE hk_type = ?",
                arguments: [identifier]
            )
        }
    }

    static func decodeAnchor(_ data: Data?, type: String) throws -> HKQueryAnchor? {
        guard let data else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        } catch {
            throw SyncPageRunnerError.repairRequired(type: type)
        }
    }

    static func archiveAnchor(_ anchor: HKQueryAnchor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
    }

    static func shouldDeferRemainingTypes(after error: Error) -> Bool {
        SyncFailurePolicy.classify(error) == .waitForUnlock
    }

    private static func stage(for error: Error) -> SyncStage {
        switch error {
        case SyncPageRunnerError.repairRequired:
            return .loadAnchor
        case SyncPageRunnerError.mappingFailed:
            return .persistDB
        default:
            return .hkQuery
        }
    }
}
