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
