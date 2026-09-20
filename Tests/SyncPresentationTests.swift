import XCTest
@testable import HealthManager

final class SyncPresentationTests: XCTestCase {
    private let finishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func test_zeroChangesAfterCompletedCheckIsNotPresentedAsNoData() {
        let presentation = SyncPresentation.make(context(
            phase: .completed,
            result: .init(
                succeeded: true,
                totalSamples: 0,
                failedTypeCount: 0,
                authorizationDeniedCount: 0,
                finishedAt: finishedAt
            )
        ))

        XCTAssertEqual(presentation.status, .checkedNoChanges)
        XCTAssertEqual(presentation.label, "已检查，无新增")
        XCTAssertTrue(presentation.detail.contains("不表示没有历史数据"))
        XCTAssertEqual(presentation.finishedAt, finishedAt)
    }

    func test_projectionPendingCannotBePresentedAsCompletedAfterRead() {
        let presentation = SyncPresentation.make(context(
            phase: .completed,
            result: .init(
                succeeded: true,
                totalSamples: 12,
                failedTypeCount: 0,
                authorizationDeniedCount: 0,
                finishedAt: finishedAt
            ),
            projectionPending: true
        ))

        XCTAssertEqual(presentation.status, .projectionPending)
        XCTAssertEqual(presentation.label, "本地指标待更新")
        XCTAssertTrue(presentation.showsRetry)
    }

    func test_protectedDataDeferralSaysWaitingForUnlockNotAuthorizationDenied() {
        let presentation = SyncPresentation.make(context(
            phase: .failed,
            result: .init(
                succeeded: false,
                totalSamples: 0,
                failedTypeCount: 1,
                authorizationDeniedCount: 4,
                finishedAt: finishedAt
            ),
            pendingTypeCount: 28,
            deferredReasons: [.waitForUnlock, .authorizationCheck]
        ))

        XCTAssertEqual(presentation.status, .waitingForUnlock)
        XCTAssertFalse(presentation.label.contains("授权"))
        XCTAssertFalse(presentation.detail.contains("全部"))
    }

    func test_authorizationDeferralDoesNotClaimAllReadPermissionsWereDenied() {
        let presentation = SyncPresentation.make(context(
            phase: .completed,
            result: .init(
                succeeded: true,
                totalSamples: 0,
                failedTypeCount: 0,
                authorizationDeniedCount: 2,
                finishedAt: finishedAt
            ),
            pendingTypeCount: 2,
            deferredReasons: [.authorizationCheck]
        ))

        XCTAssertEqual(presentation.status, .waitingForAuthorization)
        XCTAssertTrue(presentation.detail.contains("不表示全部"))
    }

    func test_partialWriteReportsRetainedCountAndFailure() {
        let presentation = SyncPresentation.make(context(
            phase: .completed,
            result: .init(
                succeeded: false,
                totalSamples: 9,
                failedTypeCount: 3,
                authorizationDeniedCount: 0,
                finishedAt: finishedAt
            )
        ))

        XCTAssertEqual(presentation.status, .partial)
        XCTAssertTrue(presentation.detail.contains("已保留写入的 9 条"))
        XCTAssertTrue(presentation.detail.contains("3 个类型未完成"))
    }

    func test_busyReadAndProjectionUseRealDescriptionsWithoutPercentages() {
        let reading = SyncPresentation.make(context(
            phase: .syncingIncremental,
            isBusy: true,
            progress: "[2/28] 增量同步 heart-rate…"
        ))
        XCTAssertEqual(reading.status, .reading)
        XCTAssertEqual(reading.detail, "[2/28] 增量同步 heart-rate…")
        XCTAssertFalse(reading.detail.contains("%"))

        let projecting = SyncPresentation.make(context(
            phase: .reconciling,
            isBusy: true,
            progress: "正在提交受影响日期"
        ))
        XCTAssertEqual(projecting.status, .projecting)
        XCTAssertEqual(projecting.detail, "正在提交受影响日期")
    }

    private func context(
        phase: SyncStateMachine.Phase,
        isBusy: Bool = false,
        progress: String = "",
        result: SyncPresentation.ResultSummary? = nil,
        pendingTypeCount: Int = 0,
        deferredReasons: [SyncDeferredReason] = [],
        projectionPending: Bool = false
    ) -> SyncPresentation.Context {
        SyncPresentation.Context(
            phase: phase,
            isBusy: isBusy,
            progressDescription: progress,
            result: result,
            pendingTypeCount: pendingTypeCount,
            deferredReasons: deferredReasons,
            projectionPending: projectionPending
        )
    }
}
