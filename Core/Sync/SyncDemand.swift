import Foundation

/// Why a piece of sync work was requested. The value is accumulated per type as a bit
/// mask inside `SyncSchedulingState` so that, for example, an `.observer` request that
/// later receives a `.manual` request for the same type is remembered as both.
///
/// Raw values are stable bit positions. Do not renumber: persisted diagnostics and
/// reason masks in older state would silently change meaning.
enum SyncReason: Int, CaseIterable, Sendable, Equatable {
    case observer = 0
    case foreground = 1
    case background = 2
    case manual = 3
    case retry = 4

    /// Single-bit flag used for per-type accumulation.
    var bitMask: Int { 1 << rawValue }

    /// A fresh execution opportunity that may follow device unlock. Observer deliveries are
    /// excluded: HealthKit can deliver them while protected data is still unavailable, and
    /// clearing the deferral there would create a locked-device retry loop. Foreground, BG,
    /// manual and explicit retry opportunities are allowed to probe HealthKit again; a failed
    /// probe will durably restore `waitForUnlock`.
    var resumesProtectedDataDeferral: Bool {
        switch self {
        case .foreground, .background, .manual, .retry:
            return true
        case .observer:
            return false
        }
    }
}

/// A single merged request for sync work.
///
/// `types` is resolved by the caller from the type catalog; an empty set never means
/// "all types" (design C02). `intentID` deduplicates retries of one logical intent
/// (one foreground pass, one manual tap) while every real observer delivery is a
/// fresh event with its own identifier.
struct SyncDemand: Sendable, Equatable {
    let types: Set<String>
    let reason: SyncReason
    let intentID: UUID
}

/// A worker's ownership ticket over exactly one sync type.
///
/// `capturedGeneration` pins the requested generation observed at claim time, so a
/// completion can only advance that type as far as the worker actually read. Later
/// requests during the same run stay pending (design C02).
struct SyncClaim: Sendable, Equatable {
    let token: UUID
    let capturedGeneration: [String: Int64]
}

/// Explicit failures raised by the scheduling reducer.
///
/// Overflow is an error rather than a wrap-around, and token mismatches are reported
/// with both identifiers so a forged/stale claim is distinguishable in logs.
enum SyncSchedulingError: Error, Equatable {
    case emptyDemand
    case generationOverflow(type: String)
    case noActiveWorker(actual: UUID)
    case tokenMismatch(expected: UUID, actual: UUID)
    /// A claim carried a type the current active claim never captured.
    case unclaimedType(String)
    /// A claim carried a generation that does not match the claim recorded at claim time.
    case capturedGenerationMismatch(expected: [String: Int64], actual: [String: Int64])
}
