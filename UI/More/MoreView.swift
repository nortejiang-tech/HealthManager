import SwiftUI

struct MoreView: View {
    var body: some View {
        NavigationStack {
            MoreScreenContent()
                .navigationTitle("更多")
                .accessibilityIdentifier("more-screen")
        }
    }
}

private struct MoreScreenContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("数据状态清楚，操作各归其位")
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("了解数据去向，快速找到需要的工具")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HMProvenanceRail(
                    title: "数据去向",
                    steps: [
                        .init(
                            title: "数据来源",
                            detail: "Apple 健康与手工记录",
                            tone: .confirmed,
                            systemImage: "heart.text.square",
                            accessibilityIdentifier: "more-provenance-local"
                        ),
                        .init(
                            title: "本机整理",
                            detail: "保存、同步与质量核对",
                            tone: .comparison,
                            systemImage: "internaldrive",
                            accessibilityIdentifier: "more-provenance-optional"
                        ),
                        .init(
                            title: "可选分析",
                            detail: "按配置发送必要内容",
                            tone: .estimate,
                            systemImage: "sparkles",
                            accessibilityIdentifier: "more-provenance-diagnostic"
                        )
                    ]
                )

                MoreActionSection(
                    title: "数据与同步",
                    rows: [
                        MoreNavigationRow(
                            title: "数据来源",
                            detail: "Apple 健康与原始样本归属",
                            systemImage: "antenna.radiowaves.left.and.right",
                            tone: .confirmed,
                            accessibilityIdentifier: "more-sources",
                            destination: AnyView(SourcesView())
                        ),
                        MoreNavigationRow(
                            title: "同步中心",
                            detail: "同步状态、回补与对账",
                            systemImage: "arrow.triangle.2.circlepath",
                            tone: .confirmed,
                            accessibilityIdentifier: "more-sync-center",
                            destination: AnyView(SyncCenterView())
                        ),
                        MoreNavigationRow(
                            title: "数据质量",
                            detail: "证据覆盖与待处理项",
                            systemImage: "waveform.badge.exclamationmark",
                            tone: .comparison,
                            accessibilityIdentifier: "more-data-quality",
                            destination: AnyView(DataQualityDetailView())
                        ),
                        MoreNavigationRow(
                            title: "告警",
                            detail: "查看缺失与异常记录",
                            systemImage: "exclamationmark.triangle",
                            tone: .actionRequired,
                            accessibilityIdentifier: "more-alerts",
                            destination: AnyView(AlertsView())
                        )
                    ]
                )

                MoreActionSection(
                    title: "分析与记录",
                    rows: [
                        MoreNavigationRow(
                            title: "日报 / 周报",
                            detail: "本地摘要与可选 AI 评注",
                            systemImage: "newspaper",
                            tone: .estimate,
                            accessibilityIdentifier: "more-summary",
                            destination: AnyView(SummaryView())
                        ),
                        MoreNavigationRow(
                            title: "运动记录",
                            detail: "Apple 健康与手工补录",
                            systemImage: "figure.run",
                            tone: .comparison,
                            accessibilityIdentifier: "more-workouts",
                            destination: AnyView(WorkoutsView())
                        )
                    ]
                )

                MoreActionSection(
                    title: "应用",
                    rows: [
                        MoreNavigationRow(
                            title: "设置",
                            detail: "权限、数据与 AI 配置",
                            systemImage: "gearshape",
                            tone: .neutral,
                            accessibilityIdentifier: "more-settings",
                            destination: AnyView(SettingsView())
                        )
                    ]
                )

            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(HMColors.background.ignoresSafeArea())
    }
}

private struct MoreActionSection: View {
    let title: String
    let rows: [MoreNavigationRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    NavigationLink(destination: row.destination) {
                        HMInformationRow(
                            systemImage: row.systemImage,
                            tone: row.tone,
                            title: row.title,
                            detail: row.detail
                        )
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(row.accessibilityIdentifier)

                    if idx < rows.count - 1 {
                        Divider()
                            .overlay(HMColors.separator)
                            .padding(.leading, 34)
                    }
                }
            }
            .background(HMColors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(HMColors.separator, lineWidth: 1)
            )
        }
    }
}

private struct MoreNavigationRow: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let tone: HMSemanticTone
    let accessibilityIdentifier: String
    let destination: AnyView

    init(
        title: String,
        detail: String,
        systemImage: String,
        tone: HMSemanticTone,
        accessibilityIdentifier: String,
        destination: AnyView
    ) {
        self.id = accessibilityIdentifier
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
        self.accessibilityIdentifier = accessibilityIdentifier
        self.destination = destination
    }
}

#Preview("More") {
    MoreView()
}

#Preview("More (Dark)") {
    MoreView()
        .preferredColorScheme(.dark)
}

#Preview("More (Accessibility Large)") {
    MoreView()
        .environment(\.dynamicTypeSize, .accessibility2)
}
