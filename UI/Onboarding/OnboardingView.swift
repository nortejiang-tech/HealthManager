import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var healthKit: HealthKitManager
    @EnvironmentObject private var sync: SyncEngine
    @State private var isRequesting = false
    @State private var localError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                permissionList
                Spacer(minLength: 0)
                actionButtons
                if let localError {
                    Text(localError).foregroundStyle(.red).font(.footnote)
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("接入 Apple 健康")
                .font(.largeTitle.bold())
            Text("我们仅从 Apple 健康读取数据，不直接访问 Garmin / 小米 等第三方接口。请确保这些 App 已先把数据同步到 Apple 健康。")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("体重、体脂、BMI、瘦体重", systemImage: "scalemass")
            Label("步数、活动能量、距离", systemImage: "figure.walk")
            Label("心率、HRV、静息心率、VO₂Max", systemImage: "heart")
            Label("睡眠分期", systemImage: "bed.double")
            Label("饮食营养（热量/三大宏量）", systemImage: "fork.knife")
        }
        .font(.callout)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await requestAuth() }
            } label: {
                if isRequesting {
                    ProgressView().controlSize(.regular)
                } else {
                    Text("授权读取健康数据")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRequesting)

            Button("我已授权，重新检测") {
                Task { await healthKit.refreshAuthorizationGate() }
            }
            .controlSize(.regular)
        }
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
