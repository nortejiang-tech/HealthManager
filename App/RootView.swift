import SwiftUI

struct RootView: View {
    @EnvironmentObject private var healthKit: HealthKitManager

    var body: some View {
        Group {
            switch healthKit.authorizationGate {
            case .unknown, .needsRequest:
                OnboardingView()
            case .partiallyGranted, .granted:
                MainTabView()
            case .denied:
                AuthorizationUnavailableView()
            }
        }
        .task {
            await healthKit.refreshAuthorizationGate()
            AppEnvironment.shared.onAuthorizationChange()
        }
        .onChange(of: healthKit.authorizationGate) { _, _ in
            AppEnvironment.shared.onAuthorizationChange()
        }
    }
}

struct MainTabView: View {
    enum MainTab: Hashable {
        case today
        case diet
        case medication
        case trends
        case more
    }

    @State private var selection: MainTab = .today

    var body: some View {
        TabView(selection: $selection) {
            TodayView { destination in
                switch destination {
                case .diet:
                    selection = .diet
                case .medication:
                    selection = .medication
                case .trends:
                    selection = .trends
                }
            }
            .tabItem { Label("今日", systemImage: "calendar") }
            .tag(MainTab.today)
            DietView()
                .tabItem { Label("饮食", systemImage: "fork.knife") }
                .tag(MainTab.diet)
            MedicationView()
                .tabItem { Label("用药", systemImage: "pills") }
                .tag(MainTab.medication)
            DashboardView()
                .tabItem { Label("趋势", systemImage: "chart.bar.fill") }
                .tag(MainTab.trends)
            MoreView()
                .tabItem { Label("更多", systemImage: "ellipsis") }
                .tag(MainTab.more)
        }
    }
}

struct AuthorizationUnavailableView: View {
    @EnvironmentObject private var healthKit: HealthKitManager
    @State private var isRefreshing = false

    var body: some View {
        AuthorizationUnavailableContent(
            isRefreshing: isRefreshing,
            onRefresh: {
                isRefreshing = true
                defer { isRefreshing = false }
                await healthKit.refreshAuthorizationGate()
            }
        )
    }
}

private struct AuthorizationUnavailableContent: View {
    let isRefreshing: Bool
    let onRefresh: () async -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HMEditorialHeader(
                    title: "Apple 健康暂不可用",
                    subtitle: "当前设备没有提供可用的 Apple 健康接口，HealthManager 因此无法读取或同步健康数据。",
                    alignment: .center
                )
                .multilineTextAlignment(.center)

                HealthUnavailableConnection()

                VStack(spacing: 0) {
                    HMInformationRow(
                        systemImage: "externaldrive.fill",
                        tone: .confirmed,
                        title: "本地记录",
                        detail: "已保存的数据不会被清除",
                        trailingText: "保留",
                        trailingTone: .confirmed
                    )
                    Divider().overlay(HMColors.separator)
                    HMInformationRow(
                        systemImage: "arrow.triangle.2.circlepath",
                        tone: .neutral,
                        title: "自动同步",
                        detail: "等待 Apple 健康接口恢复",
                        trailingText: "暂停"
                    )
                    Divider().overlay(HMColors.separator)
                    HMInformationRow(
                        systemImage: "square.and.pencil",
                        tone: .neutral,
                        title: "饮食与用药记录",
                        detail: "连接恢复后可继续进入主界面使用",
                        trailingText: "未删除"
                    )
                }
                .padding(.horizontal, 16)
                .hmSurface(cornerRadius: 18)

                Button {
                    Task { await onRefresh() }
                } label: {
                    HStack(spacing: 10) {
                        if isRefreshing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isRefreshing ? "正在重新检测" : "重新检测")
                            .frame(maxWidth: .infinity)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(HMColors.actionRequired)
                .disabled(isRefreshing)
                .accessibilityIdentifier("health-unavailable-retry")

                Label(
                    "Apple 健康稍后恢复可用时，重新检测即可继续；本地数据不会因此被删除。",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 24)
            .padding(.top, 56)
            .padding(.bottom, 36)
        }
        .background(HMColors.background.ignoresSafeArea())
    }
}

private struct HealthUnavailableConnection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 12) {
                    endpoint(systemImage: "heart.fill", label: "Apple 健康")
                    HMEvidenceTag(
                        tone: .actionRequired,
                        text: "连接未建立",
                        systemImage: "xmark.circle.fill"
                    )
                    endpoint(systemImage: "externaldrive.fill", label: "HealthManager")
                }
            } else {
                HStack(spacing: 14) {
                    endpoint(systemImage: "heart.fill", label: "Apple 健康")
                    HMEvidenceTag(
                        tone: .actionRequired,
                        text: "连接未建立",
                        systemImage: "xmark.circle.fill"
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    endpoint(systemImage: "externaldrive.fill", label: "HealthManager")
                }
            }
        }
        .padding(20)
        .hmSurface(cornerRadius: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Apple 健康与 HealthManager 的连接尚未建立")
    }

    private func endpoint(systemImage: String, label: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title.weight(.semibold))
                .foregroundStyle(HMColors.confirmed)
                .frame(width: 64, height: 64)
                .background(HMColors.confirmed.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Apple Health 暂不可用") {
    AuthorizationUnavailableContent(
        isRefreshing: false,
        onRefresh: { }
    )
}

#Preview("Apple Health 暂不可用（深色）") {
    AuthorizationUnavailableContent(
        isRefreshing: false,
        onRefresh: { }
    )
    .preferredColorScheme(.dark)
}

#Preview("Apple Health 暂不可用（大字体）") {
    AuthorizationUnavailableContent(
        isRefreshing: false,
        onRefresh: { }
    )
    .environment(\.dynamicTypeSize, .accessibility2)
}
