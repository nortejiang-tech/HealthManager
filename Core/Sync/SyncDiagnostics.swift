import Foundation

/// Structured diagnostics for sync failures. Surfaced in SyncCenter so the user can see
/// which HK type failed at which stage, instead of just "同步失败：xxx".
enum SyncStage: String, Equatable {
    case loadAnchor
    case hkQuery
    case mapSamples
    case persistDB
    case saveAnchor
    case sourceCoverage
}

struct SyncTypeError: Equatable {
    let hkType: String
    let stage: SyncStage
    let underlying: String
    /// True when the underlying error was HKErrorDomain authorizationDenied / authorizationNotDetermined.
    /// SyncCenter renders these with a lock icon (vs red triangle) and the coordinator does NOT
    /// promote them into the job-level firstError, so the overall job can still be "succeeded".
    let isAuthDenied: Bool
    let occurredAt: Date
}

extension SyncTypeError {
    /// Detect HealthKit authorization-denied errors, regardless of whether they arrived as
    /// our `HealthKitManager.HKError.authorizationDenied` or as a wrapped NSError carrying
    /// `HKErrorDomain` + `errorAuthorizationDenied` / `errorAuthorizationNotDetermined`.
    static func isAuthorizationDenied(_ error: Error) -> Bool {
        if let hk = error as? HealthKitManager.HKError, case .authorizationDenied = hk {
            return true
        }
        if let hk = error as? HealthKitManager.HKError, case .queryFailed(let underlying) = hk {
            return isAuthorizationDenied(underlying)
        }
        let ns = error as NSError
        if ns.domain == "com.apple.healthkit" || ns.domain.contains("HealthKit") {
            // HKError.Code.errorAuthorizationDenied == 4, errorAuthorizationNotDetermined == 5
            return ns.code == 4 || ns.code == 5
        }
        return false
    }
}
