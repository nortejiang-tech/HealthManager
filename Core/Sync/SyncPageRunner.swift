import Foundation

struct SyncFetchedPage {
    let addedRows: [HealthSampleRaw]
    let deletedUUIDs: [String]
    let newAnchorData: Data?

    var isDrained: Bool { addedRows.isEmpty && deletedUUIDs.isEmpty }
}

struct SyncPageBudget: Equatable, Sendable {
    let maximumPages: Int
    let deadline: Date

    init(maximumPages: Int, deadline: Date) {
        self.maximumPages = max(0, maximumPages)
        self.deadline = deadline
    }
}

enum SyncPageRunState: Equatable, Sendable {
    case drained
    case hasPending
}

struct SyncPageRunResult: Equatable, Sendable {
    let state: SyncPageRunState
    let pagesCommitted: Int
    let actualInserted: Int
    let actualDeleted: Int
    let unknownTombstones: Int
}

enum SyncPageRunnerError: Error, Equatable {
    case invalidBudget
    case nonEmptyPageMissingAnchor(type: String)
    case mappingFailed(type: String, sampleID: String)
    case repairRequired(type: String)
}

/// Executes one bounded slice for one already-claimed HealthKit type.
///
/// A page is the durability boundary: raw rows, tombstones, dirty dates and the returned
/// anchor are committed together by `SyncWorkStore`. A type is complete only after an empty
/// added+deleted page confirms drain. Reaching the page/deadline budget leaves the captured
/// generation pending so another execution opportunity resumes at the last committed anchor.
struct SyncPageRunner: @unchecked Sendable {
    static let pageSize = 1_000

    private let workStore: SyncWorkStore
    private let calendar: Calendar
    private let projectionVersion: Int
    private let now: @Sendable () -> Date

    init(
        workStore: SyncWorkStore,
        calendar: Calendar = .current,
        projectionVersion: Int = 1,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.workStore = workStore
        self.calendar = calendar
        self.projectionVersion = projectionVersion
        self.now = now
    }

    func run(
        claim: SyncClaim,
        initialAnchorData: Data?,
        budget: SyncPageBudget,
        fetchPage: @escaping (_ anchorData: Data?, _ limit: Int) async throws -> SyncFetchedPage
    ) async throws -> SyncPageRunResult {
        guard budget.maximumPages > 0 else { throw SyncPageRunnerError.invalidBudget }

        var anchorData = initialAnchorData
        var pagesCommitted = 0
        var inserted = 0
        var deleted = 0
        var unknownTombstones = 0

        while pagesCommitted < budget.maximumPages, now() < budget.deadline {
            try Task.checkCancellation()
            let page = try await fetchPage(anchorData, Self.pageSize)
            let type = try claimedType(from: claim)
            if !page.isDrained, page.newAnchorData == nil {
                throw SyncPageRunnerError.nonEmptyPageMissingAnchor(type: type)
            }

            let commit = try workStore.commitPage(.init(
                claim: claim,
                addedRows: page.addedRows,
                deletedUUIDs: page.deletedUUIDs,
                newAnchorData: page.newAnchorData,
                drained: page.isDrained,
                calendar: calendar,
                projectionVersion: projectionVersion,
                committedAt: now()
            ))
            pagesCommitted += 1
            inserted += commit.actualInserted
            deleted += commit.actualDeleted
            unknownTombstones += commit.unknownTombstones
            anchorData = page.newAnchorData ?? anchorData

            if page.isDrained {
                return SyncPageRunResult(
                    state: .drained,
                    pagesCommitted: pagesCommitted,
                    actualInserted: inserted,
                    actualDeleted: deleted,
                    unknownTombstones: unknownTombstones
                )
            }
        }

        return SyncPageRunResult(
            state: .hasPending,
            pagesCommitted: pagesCommitted,
            actualInserted: inserted,
            actualDeleted: deleted,
            unknownTombstones: unknownTombstones
        )
    }

    private func claimedType(from claim: SyncClaim) throws -> String {
        guard claim.capturedGeneration.count == 1, let type = claim.capturedGeneration.keys.first else {
            throw SyncWorkStoreError.invalidClaim
        }
        return type
    }
}
