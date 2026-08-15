import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var healthKit: HealthKitManager
    @EnvironmentObject private var backup: BackupManager
    @State private var isRequesting = false
    @State private var localError: String?

    var body: some View {
        OnboardingContent(
            isRequesting: isRequesting,
            localError: localError,
            backup: backup,
            onRequestAuth: {
                await requestAuth()
            },
            onRetry: {
                await healthKit.refreshAuthorizationGate()
            }
        )
    }

    private func requestAuth() async {
        isRequesting = true
        defer { isRequesting = false }
        do {
            try await healthKit.requestAuthorization()
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct OnboardingContent: View {
    let isRequesting: Bool
    let localError: String?
    @ObservedObject var backup: BackupManager
    let onRequestAuth: () async -> Void
    let onRetry: () async -> Void

    @State private var showRestorePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HMEditorialHeader(
                    title: "把 Apple 健康作为数据入口",
                    subtitle: "HealthManager 只连接 Apple 健康，不直接登录 Garmin、小米或其他第三方账户。"
                )
                .accessibilityIdentifier("onboarding-header")

                OnboardingDataPath()

                VStack(alignment: .leading, spacing: 12) {
                    Text("授权将允许 HealthManager：")
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: 0) {
                        HMInformationRow(
                            systemImage: "book.closed",
                            tone: .confirmed,
                            title: "读取",
                            detail: "体重与体成分、活动、心率、睡眠和饮食营养"
                        )
                        Divider().overlay(HMColors.separator)
                        HMInformationRow(
                            systemImage: "square.and.pencil",
                            tone: .confirmed,
                            title: "按需写回",
                            detail: "当你在 App 内保存饮食时，可把热量与三大营养写回 Apple 健康"
                        )
                    }
                    .padding(.horizontal, 16)
                    .hmSurface(cornerRadius: 18)
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(HMColors.confirmed)
                        .accessibilityHidden(true)
                    Text("此步骤不会调用外部 AI；授权范围可随时在系统设置中修改。")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(HMColors.confirmed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HMColors.confirmed.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboarding-ai-note")

                if let localError {
                    HMInlineRecovery(
                        title: "未能完成授权",
                        message: "系统授权请求没有完成。你可以保留当前页面并重新尝试。",
                        technicalDetails: localError,
                        actionTitle: "重新请求授权",
                        onAction: {
                            Task { await onRequestAuth() }
                        },
                        titleAccessibilityIdentifier: "onboarding-error-title",
                        actionAccessibilityIdentifier: "onboarding-retry-auth"
                    )
                }

                actionButtons

                restoreSection

                Text("下一步由 iOS 展示具体数据类型，你可以在系统授权表中逐项选择。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 36)
        }
        .background(HMColors.background.ignoresSafeArea())
    }

    private var restoreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("可选：恢复历史数据")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            HMInformationRow(
                systemImage: "arrow.down.doc",
                tone: .neutral,
                title: "从备份文件夹恢复",
                detail: "选择之前设置过的备份文件夹，导入解析后的历史数据；只补缺、不覆盖，可重复执行。"
            )

            Button {
                showRestorePicker = true
            } label: {
                if backup.isRestoring {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("恢复中…")
                    }
                } else {
                    Label("选择备份文件夹并恢复…", systemImage: "folder.badge.questionmark")
                }
            }
            .disabled(backup.isRestoring)
            .accessibilityIdentifier("onboarding-restore-backup")

            if let error = backup.lastRestoreError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(HMColors.actionRequired)
            }
            if let summary = backup.lastRestoreSummary {
                Text("恢复完成：新增 \(summary.totalImported) 行，已存在而跳过 \(summary.totalSkipped) 行。")
                    .font(.footnote)
                    .foregroundStyle(HMColors.confirmed)
            }
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
        .sheet(isPresented: $showRestorePicker) {
            FolderPicker { url in
                Task { await backup.restore(from: url) }
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await onRequestAuth() }
            } label: {
                HStack(spacing: 10) {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isRequesting ? "正在打开系统授权" : "继续到系统授权")
                        .frame(maxWidth: .infinity)
                }
                .frame(minHeight: 44)
            }
            .font(.body.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(HMColors.confirmed)
            .disabled(isRequesting)
            .accessibilityIdentifier("onboarding-request-auth")

            Button("我已授权，重新检测") {
                Task { await onRetry() }
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(HMColors.confirmed)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.plain)
            .disabled(isRequesting)
            .accessibilityIdentifier("onboarding-recheck")
        }
    }
}

private struct OnboardingDataPath: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                horizontalPath
                verticalPath
            }

            Divider().overlay(HMColors.separator)

            Label(
                "第三方数据需先由对应 App 写入 Apple 健康。",
                systemImage: "info.circle"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .hmSurface(cornerRadius: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("数据路径：手表或健康 App 写入 Apple 健康，再由 HealthManager 读取并保存在本机数据库")
    }

    private var horizontalPath: some View {
        HStack(alignment: .top, spacing: 8) {
            OnboardingPathNode(
                systemImage: "applewatch",
                title: "手表与健康 App"
            )
            pathArrow("arrow.right")
            OnboardingPathNode(
                systemImage: "heart.fill",
                title: "Apple 健康"
            )
            pathArrow("arrow.right")
            OnboardingPathNode(
                systemImage: "externaldrive.fill",
                title: "本机数据库"
            )
        }
    }

    private var verticalPath: some View {
        VStack(spacing: 10) {
            OnboardingPathNode(
                systemImage: "applewatch",
                title: "手表与健康 App"
            )
            pathArrow("arrow.down")
            OnboardingPathNode(
                systemImage: "heart.fill",
                title: "Apple 健康"
            )
            pathArrow("arrow.down")
            OnboardingPathNode(
                systemImage: "externaldrive.fill",
                title: "HealthManager 本机数据库"
            )
        }
    }

    private func pathArrow(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(HMColors.confirmed)
            .frame(minWidth: 20, minHeight: 54)
            .accessibilityHidden(true)
    }
}

private struct OnboardingPathNode: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(HMColors.confirmed)
                .frame(width: 54, height: 54)
                .background(HMColors.confirmed.opacity(0.09), in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Onboarding Default") {
    OnboardingContent(
        isRequesting: false,
        localError: nil,
        backup: BackupManager(database: DatabaseManager.makeInMemoryForTesting()),
        onRequestAuth: { },
        onRetry: { }
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}

#Preview("Onboarding Dark") {
    OnboardingContent(
        isRequesting: false,
        localError: nil,
        backup: BackupManager(database: DatabaseManager.makeInMemoryForTesting()),
        onRequestAuth: { },
        onRetry: { }
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .preferredColorScheme(.dark)
}

#Preview("Onboarding Accessibility Large") {
    OnboardingContent(
        isRequesting: false,
        localError: nil,
        backup: BackupManager(database: DatabaseManager.makeInMemoryForTesting()),
        onRequestAuth: { },
        onRetry: { }
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
    .environment(\.dynamicTypeSize, .accessibility2)
}

#Preview("Onboarding Error") {
    OnboardingContent(
        isRequesting: false,
        localError: "HealthKit 请求暂时未完成。",
        backup: BackupManager(database: DatabaseManager.makeInMemoryForTesting()),
        onRequestAuth: { },
        onRetry: { }
    )
    .environment(\.locale, Locale(identifier: "zh_CN"))
}
