import XCTest
import HealthKit
@testable import HealthManager

final class SyncFailurePolicyTests: XCTestCase {
    func test_databaseInaccessibleWaitsForUnlockUsingSDKErrorCode() {
        let error = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "arbitrary localized text"]
        )

        XCTAssertEqual(SyncFailurePolicy.classify(error), .waitForUnlock)
    }

    func test_cancellationErrorIsCancelled() {
        XCTAssertEqual(SyncFailurePolicy.classify(CancellationError()), .cancelled)
    }

    func test_healthKitQueryWrapperIsRecursivelyUnwrapped() {
        let underlying = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue
        )
        let wrapped = HealthKitManager.HKError.queryFailed(underlying: underlying)

        XCTAssertEqual(SyncFailurePolicy.classify(wrapped), .waitForUnlock)
    }

    func test_nserrorUnderlyingErrorIsRecursivelyUnwrapped() {
        let underlying = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorAuthorizationDenied.rawValue
        )
        let wrapper = NSError(
            domain: "example.wrapper",
            code: 99,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        XCTAssertEqual(SyncFailurePolicy.classify(wrapper), .authorizationCheck)
    }

    func test_allHealthKitAuthorizationCodesRequestAuthorizationCheck() {
        let codes: [HKError.Code] = [
            .errorAuthorizationDenied,
            .errorAuthorizationNotDetermined,
            .errorRequiredAuthorizationDenied
        ]

        for code in codes {
            let error = NSError(domain: HKErrorDomain, code: code.rawValue)
            XCTAssertEqual(SyncFailurePolicy.classify(error), .authorizationCheck)
        }
    }

    func test_userCancelledHealthKitOperationIsCancelled() {
        let error = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorUserCanceled.rawValue
        )

        XCTAssertEqual(SyncFailurePolicy.classify(error), .cancelled)
    }

    func test_noDataIsFailureRatherThanAuthorizationError() {
        let error = NSError(
            domain: HKErrorDomain,
            code: HKError.Code.errorNoData.rawValue
        )

        XCTAssertEqual(SyncFailurePolicy.classify(error), .failure)
    }

    func test_unknownDomainAndCodeArePreservedWithoutMessageMatching() {
        let error = NSError(
            domain: "example.unknown",
            code: 731,
            userInfo: [
                NSLocalizedDescriptionKey: "authorization denied database inaccessible cancelled"
            ]
        )

        XCTAssertEqual(
            SyncFailurePolicy.classify(error),
            .unknown(domain: "example.unknown", code: 731)
        )
    }

    func test_unknownHealthKitCodeIsPreserved() {
        let error = NSError(domain: HKErrorDomain, code: 9_999)

        XCTAssertEqual(
            SyncFailurePolicy.classify(error),
            .unknown(domain: HKErrorDomain, code: 9_999)
        )
    }
}
