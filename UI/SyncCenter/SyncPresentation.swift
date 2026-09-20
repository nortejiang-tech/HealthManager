import Foundation

struct SyncPresentation {
    enum Status: Equatable {
        case idle
        case waitingForAuthorization
        case waitingForUnlock
        case reading
        case waitingForExternalApp
        case projecting
        case projectionPending
        case checkedNoChanges
        case updated
        case partial
        case failed
    }

    struct ResultSummary: Equatable {
        let succeeded: Bool
        let totalSamples: Int
        let failedTypeCount: Int
        let authorizationDeniedCount: Int
        let finishedAt: Date
    }

    struct Context: Equatable {
        let phase: SyncStateMachine.Phase
        let isBusy: Bool
        let progressDescription: String
        let result: ResultSummary?
        let pendingTypeCount: Int
        let deferredReasons: [SyncDeferredReason]
        let projectionPending: Bool
    }

    let status: Status
    let label: String
    let detail: String
    let finishedAt: Date?

    var tone: HMSemanticTone {
        switch status {
        case .updated, .checkedNoChanges:
            return .confirmed
        case .reading, .projecting, .waitingForExternalApp:
            return .comparison
        case .waitingForAuthorization, .waitingForUnlock, .projectionPending, .partial, .failed:
            return .actionRequired
        case .idle:
            return .neutral
        }
    }

    var icon: String {
        switch status {
        case .idle: return "pause.circle"
        case .waitingForAuthorization: return "lock.shield"
        case .waitingForUnlock: return "lock.fill"
        case .reading: return "arrow.down.circle"
        case .waitingForExternalApp: return "arrow.triangle.2.circlepath"
        case .projecting, .projectionPending: return "chart.bar.doc.horizontal"
        case .checkedNoChanges, .updated: return "checkmark.circle.fill"
        case .partial, .failed: return "exclamationmark.triangle.fill"
        }
    }

    var showsRetry: Bool {
        switch status {
        case .waitingForUnlock, .waitingForAuthorization, .projectionPending, .partial, .failed:
            return true
        default:
            return false
        }
    }

    var isFailureLike: Bool {
        status == .projectionPending || status == .partial || status == .failed
    }

    static func make(_ context: Context) -> SyncPresentation {
        let finishedAt = context.result?.finishedAt

        if context.deferredReasons.contains(.waitForUnlock) {
            return SyncPresentation(
                status: .waitingForUnlock,
                label: "等待设备解锁",
                detail: "Apple 健康受保护数据暂不可读；请求已保留，解锁后可以继续。",
                finishedAt: finishedAt
            )
        }
        if context.phase == .requestingAuth || context.deferredReasons.contains(.authorizationCheck) {
            return SyncPresentation(
                status: .waitingForAuthorization,
                label: "等待授权检查",
                detail: "部分类型需要重新检查授权；这不表示全部健康数据都被拒绝。",
                finishedAt: finishedAt
            )
        }
        if context.phase == .waitingExternalSync {
            return SyncPresentation(
                status: .waitingForExternalApp,
                label: "等待外部 App 同步",
                detail: "当前未占用本地同步执行通道；返回后会继续第二次读取。",
                finishedAt: finishedAt
            )
        }
        if context.isBusy {
            if context.phase == .reconciling || context.projectionPending {
                return SyncPresentation(
                    status: .projecting,
                    label: "正在更新本地指标",
                    detail: context.progressDescription.isEmpty ? "HealthKit 读取已完成，正在提交受影响日期。" : context.progressDescription,
                    finishedAt: nil
                )
            }
            return SyncPresentation(
                status: .reading,
                label: "正在读取 Apple 健康",
                detail: context.progressDescription.isEmpty ? "正在执行有界增量读取。" : context.progressDescription,
                finishedAt: nil
            )
        }
        if context.projectionPending {
            return SyncPresentation(
                status: .projectionPending,
                label: "本地指标待更新",
                detail: "健康记录已读取，但仍有日期没有完成投影；不会把本轮显示为已完成。",
                finishedAt: finishedAt
            )
        }
        if context.phase == .failed {
            return SyncPresentation(
                status: .failed,
                label: "本轮未完成",
                detail: context.progressDescription.isEmpty ? "同步在完成全部必需阶段前失败。" : context.progressDescription,
                finishedAt: finishedAt
            )
        }
        if context.phase == .completed, let result = context.result {
            if !result.succeeded || result.failedTypeCount > 0 {
                let retained = result.totalSamples > 0 ? "已保留写入的 \(result.totalSamples) 条记录；" : ""
                return SyncPresentation(
                    status: result.totalSamples > 0 ? .partial : .failed,
                    label: result.totalSamples > 0 ? "部分完成" : "本轮未完成",
                    detail: "\(retained)仍有 \(max(result.failedTypeCount, 1)) 个类型未完成。",
                    finishedAt: result.finishedAt
                )
            }
            if context.pendingTypeCount > 0 || result.authorizationDeniedCount > 0 {
                let reason = result.authorizationDeniedCount > 0
                    ? "\(result.authorizationDeniedCount) 个类型等待授权或不可读"
                    : "\(context.pendingTypeCount) 个类型仍有持久待办"
                return SyncPresentation(
                    status: .partial,
                    label: "已完成可用部分",
                    detail: "其他类型已经检查；\(reason)。",
                    finishedAt: result.finishedAt
                )
            }
            if result.totalSamples == 0 {
                return SyncPresentation(
                    status: .checkedNoChanges,
                    label: "已检查，无新增",
                    detail: "本轮读取和本地指标更新均已完成；零变化不表示没有历史数据。",
                    finishedAt: result.finishedAt
                )
            }
            return SyncPresentation(
                status: .updated,
                label: "已更新 \(result.totalSamples) 条",
                detail: "读取和本地指标更新已完成；Bridge 与备份导出按各自状态继续。",
                finishedAt: result.finishedAt
            )
        }

        return SyncPresentation(
            status: .idle,
            label: "空闲",
            detail: context.progressDescription.isEmpty ? "等待下一次自动或手动检查。" : context.progressDescription,
            finishedAt: finishedAt
        )
    }
}

struct SyncRuntimePresentationEvidence: Equatable {
    static let empty = SyncRuntimePresentationEvidence(
        pendingTypeCount: 0,
        deferredReasons: [],
        projectionPending: false
    )

    let pendingTypeCount: Int
    let deferredReasons: [SyncDeferredReason]
    let projectionPending: Bool
}
