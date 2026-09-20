import Foundation

/// Foundation-only reducer for coalescing sync demand and assigning one type at a time.
/// It owns no Task or timer; a later runner supplies execution opportunities and tokens.
struct SyncSchedulingState: Equatable {
    private(set) var requestedGeneration: [String: Int64]
    private(set) var completedGeneration: [String: Int64]
    private(set) var reasonMaskByType: [String: Int]
    private(set) var activeToken: UUID?
    private(set) var deferredTypes: Set<String>

    private var handledIntentIDs: Set<UUID>
    private var activeClaim: SyncClaim?
    private var lastClaimedType: String?

    init(
        requestedGeneration: [String: Int64] = [:],
        completedGeneration: [String: Int64] = [:]
    ) {
        self.requestedGeneration = requestedGeneration
        self.completedGeneration = completedGeneration
        self.reasonMaskByType = [:]
        self.activeToken = nil
        self.deferredTypes = []
        self.handledIntentIDs = []
        self.activeClaim = nil
        self.lastClaimedType = nil
    }

    var pendingTypes: Set<String> {
        Set(requestedGeneration.compactMap { type, requested in
            requested > completedGeneration[type, default: 0] ? type : nil
        })
    }

    var readyTypes: Set<String> {
        pendingTypes.subtracting(deferredTypes)
    }

    var isRunning: Bool {
        activeToken != nil
    }

    /// Merge one logical demand. Overflow checks happen for the complete type set before
    /// any state changes, so a rejected multi-type demand is atomic.
    @discardableResult
    mutating func submit(_ demand: SyncDemand) throws -> Bool {
        guard !demand.types.isEmpty else {
            throw SyncSchedulingError.emptyDemand
        }
        guard !handledIntentIDs.contains(demand.intentID) else {
            return false
        }

        let orderedTypes = demand.types.sorted()
        for type in orderedTypes where requestedGeneration[type, default: 0] == .max {
            throw SyncSchedulingError.generationOverflow(type: type)
        }

        for type in orderedTypes {
            requestedGeneration[type, default: 0] += 1
            reasonMaskByType[type, default: 0] |= demand.reason.bitMask
        }
        handledIntentIDs.insert(demand.intentID)
        return true
    }

    /// Claim one ready type. The lexicographic cursor rotates after every claim so a type
    /// that was re-requested while running cannot starve another ready type.
    mutating func claimNext(token: UUID) -> SyncClaim? {
        guard activeToken == nil else { return nil }
        let orderedReady = readyTypes.sorted()
        guard !orderedReady.isEmpty else { return nil }

        let selected: String
        if let lastClaimedType,
           let next = orderedReady.first(where: { $0 > lastClaimedType }) {
            selected = next
        } else {
            selected = orderedReady[0]
        }

        let claim = SyncClaim(
            token: token,
            capturedGeneration: [selected: requestedGeneration[selected, default: 0]]
        )
        activeToken = token
        activeClaim = claim
        lastClaimedType = selected
        return claim
    }

    /// Complete only the generations captured by this worker. Later demand remains pending.
    mutating func complete(_ claim: SyncClaim) throws {
        try validate(claim)

        for (type, captured) in claim.capturedGeneration {
            let requested = requestedGeneration[type, default: 0]
            guard captured <= requested else {
                throw SyncSchedulingError.capturedGenerationMismatch(
                    expected: activeClaim?.capturedGeneration ?? [:],
                    actual: claim.capturedGeneration
                )
            }
            completedGeneration[type] = max(completedGeneration[type, default: 0], captured)
        }
        clearActiveClaim()
    }

    /// Release a failed/yielded claim without advancing its generation. Deferred work stays
    /// pending but is excluded from ready selection until an external event resumes it.
    mutating func release(
        _ claim: SyncClaim,
        deferring types: Set<String> = []
    ) throws {
        try validate(claim)

        let claimedTypes = Set(claim.capturedGeneration.keys)
        guard types.isSubset(of: claimedTypes) else {
            let invalid = types.subtracting(claimedTypes).sorted().first ?? ""
            throw SyncSchedulingError.unclaimedType(invalid)
        }
        deferredTypes.formUnion(types)
        clearActiveClaim()
    }

    mutating func resume(_ types: Set<String>) {
        deferredTypes.subtract(types)
    }

    private func validate(_ claim: SyncClaim) throws {
        guard let activeToken else {
            throw SyncSchedulingError.noActiveWorker(actual: claim.token)
        }
        guard activeToken == claim.token else {
            throw SyncSchedulingError.tokenMismatch(expected: activeToken, actual: claim.token)
        }
        guard activeClaim?.capturedGeneration == claim.capturedGeneration else {
            throw SyncSchedulingError.capturedGenerationMismatch(
                expected: activeClaim?.capturedGeneration ?? [:],
                actual: claim.capturedGeneration
            )
        }
    }

    private mutating func clearActiveClaim() {
        activeToken = nil
        activeClaim = nil
    }
}
