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
                AuthorizationDeniedView()
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
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("仪表盘", systemImage: "heart.text.square") }
            SyncCenterView()
                .tabItem { Label("同步中心", systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}

struct AuthorizationDeniedView: View {
    @EnvironmentObject private var healthKit: HealthKitManager

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            Text("健康权限被拒绝")
                .font(.title2.bold())
            Text("请前往 设置 → 隐私 → 健康 → 健康管理 中开启读取权限。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("重新检查权限") {
                Task { await healthKit.refreshAuthorizationGate() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
