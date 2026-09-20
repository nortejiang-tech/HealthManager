import Foundation
import HealthKit

/// What a caller should *do* after a sync-side failure.
///
/// The set is deliberately small so coordinators can drive retry / prompt /
/// park behaviour from one value instead of sniffing error messages.
///
/// Note: `.transient` and `.repairRequired` are intentionally not produced by
/// this stage's classifier — there is not yet enough verified evidence to map
/// any concrete HealthKit condition onto them. They are reserved for later,
/// explicitly authorised entry points. Everything the classifier cannot prove
/// falls into `.unknown(domain:code:)` so the original identity is preserved.
enum SyncFailureDisposition: Equatable {
    /// HealthKit's store is locked (device locked / data protection class).
    case waitForUnlock
    /// Authorization is missing, undetermined, or a required permission was denied.
    case authorizationCheck
    /// The operation itself was cancelled (structured cancellation or user cancel).
    case cancelled
    /// Resumable failure worth an automatic retry. Reserved, not yet emitted.
    case transient
    /// Persistent inconsistency that needs an explicit repair pass. Reserved.
    case repairRequired
    /// Definitive failure for this operation (unsupported, no data, bad request).
    case failure
    /// Unrecognised error; domain and code are kept for diagnostics.
    case unknown(domain: String, code: Int)
}

/// Maps wrapped HealthKit errors onto a `SyncFailureDisposition`.
///
/// Classification is driven only by error identity (`CancellationError`,
/// `HealthKitManager.HKError` cases, `HKErrorDomain` + `HKError.Code` raw
/// values) and by unwrapping `queryFailed(underlying:)` /
/// `NSUnderlyingErrorKey`. Localized descriptions and message text are never
/// inspected, because they are localized and not stable.
enum SyncFailurePolicy {
    /// Maximum wrapper depth explored before giving up. Bounds recursion against
    /// self-referential / cyclic `NSUnderlyingErrorKey` chains.
    static let maxUnwrapDepth = 8

    static func classify(_ error: Error) -> SyncFailureDisposition {
        var current: Error = error

        for _ in 0..<maxUnwrapDepth {
            if current is CancellationError {
                return .cancelled
            }

            if let hkError = current as? HealthKitManager.HKError {
                switch hkError {
                case .authorizationDenied:
                    return .authorizationCheck
                case .healthDataUnavailable, .typeUnavailable:
                    return .failure
                case .queryFailed(let underlying):
                    current = underlying
                    continue
                }
            }

            let ns = current as NSError
            if ns.domain == HKErrorDomain {
                return classifyHealthKitCode(ns.code)
            }

            guard let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error else {
                return .unknown(domain: ns.domain, code: ns.code)
            }
            current = underlying
        }

        // Depth budget exhausted: report the wrapper we stopped on rather than loop.
        let stopped = current as NSError
        return .unknown(domain: stopped.domain, code: stopped.code)
    }

    /// Translate an `HKError.Code` raw value. Codes that the SDK enum cannot be
    /// built from stay `.unknown` with their original code.
    private static func classifyHealthKitCode(_ code: Int) -> SyncFailureDisposition {
        guard let hkCode = HKError.Code(rawValue: code) else {
            return .unknown(domain: HKErrorDomain, code: code)
        }

        switch hkCode {
        case .errorDatabaseInaccessible:
            return .waitForUnlock
        case .errorAuthorizationDenied,
             .errorAuthorizationNotDetermined,
             .errorRequiredAuthorizationDenied:
            return .authorizationCheck
        case .errorUserCanceled:
            return .cancelled
        default:
            // Objective-C extensible enums can be constructed from an arbitrary raw
            // value, so a non-nil initializer does not prove that the SDK declares it.
            let highestKnownCode: Int
            if #available(iOS 18.0, *) {
                highestKnownCode = HKError.Code.errorNotPermissibleForGuestUserMode.rawValue
            } else {
                highestKnownCode = HKError.Code.errorBackgroundWorkoutSessionNotAllowed.rawValue
            }
            if (0...highestKnownCode).contains(code) {
                return .failure
            }
            return .unknown(domain: HKErrorDomain, code: code)
        }
    }
}
