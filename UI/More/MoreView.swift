import SwiftUI

struct MoreView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("数据与同步") {
                    NavigationLink {
                        SourcesView()
                    } label: {
                        rowLabel("数据来源", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("more-sources")

                    NavigationLink {
                        SyncCenterView()
                    } label: {
                        rowLabel("同步中心", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .accessibilityIdentifier("more-sync-center")

                    NavigationLink {
                        DataQualityDetailView()
                    } label: {
                        rowLabel("数据质量", systemImage: "waveform.badge.exclamationmark")
                    }
                    .accessibilityIdentifier("more-data-quality")

                    NavigationLink {
                        AlertsView()
                    } label: {
                        rowLabel("告警", systemImage: "exclamationmark.triangle")
                    }
                    .accessibilityIdentifier("more-alerts")
                }

                Section("分析与记录") {
                    NavigationLink {
                        SummaryView()
                    } label: {
                        rowLabel("日报 / 周报", systemImage: "newspaper")
                    }
                    .accessibilityIdentifier("more-summary")

                    NavigationLink {
                        WorkoutsView()
                    } label: {
                        rowLabel("运动记录", systemImage: "figure.run")
                    }
                    .accessibilityIdentifier("more-workouts")
                }

                Section("应用") {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        rowLabel("设置", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("more-settings")
                }
            }
            .navigationTitle("更多")
            .accessibilityIdentifier("more-screen")
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
            Text(title)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
