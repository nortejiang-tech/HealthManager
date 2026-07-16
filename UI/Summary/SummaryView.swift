import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var today: DailySummary?
    @State private var week: WeeklySummary?
    @State private var generating: Bool = false
    @State private var llmGeneratingDaily: Bool = false
    @State private var llmGeneratingWeekly: Bool = false
    @State private var llmError: String?
    @State private var loadError: String?
    @State private var hasLoadedSummaries: Bool = false

    private var generator: SummaryGenerator { SummaryGenerator(database: environment.database) }

    var body: some View {
        List {
            Section {
                HMDecisionLens(
                    title: "本地摘要是主结果",
                    text: "日报和周报先在本机按现有记录确定性聚合。若 AI 摘要已开启且配置完成，会在本地结果之后单独请求模型评注。",
                    tone: .confirmed,
                    systemImage: "lock.doc",
                    primaryActionTitle: generating ? "正在生成…" : "生成日报 + 周报",
                    primaryActionIcon: "doc.badge.gearshape",
                    primaryActionTone: .comparison,
                    primaryAction: {
                        guard !generating else { return }
                        Task { await generateBoth() }
                    }
                )
                .allowsHitTesting(!generating)
                .opacity(generating ? 0.72 : 1)
            }

            if !LLMConfig.isConfigured, LLMConfig.enabled {
                Section {
                    HMEvidenceTag(
                        tone: .actionRequired,
                        text: "AI 评注尚未配置",
                        systemImage: "key.fill"
                    )
                    NavigationLink {
                        LLMSettingsView()
                    } label: {
                        Label("配置 AI 摘要接口", systemImage: "key.fill")
                    }
                } footer: {
                    Text("AI 摘要默认开启，但 Base URL / 模型 / API Key 还未填写。配置后下次生成会附带 LLM 评注。")
                }
            }

            Section("今日日报") {
                if let s = today, let text = s.summaryText, !text.isEmpty {
                    HMEvidenceTag(
                        tone: .confirmed,
                        text: "本地确定性摘要",
                        systemImage: "lock.doc.fill"
                    )
                    Text(text)
                        .font(.system(.body, design: .rounded))
                        .textSelection(.enabled)
                    Text("生成于 " + formatTime(s.generatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                    llmBlock(
                        text: s.llmText,
                        model: s.llmModel,
                        generatedAt: s.llmGeneratedAt,
                        loading: llmGeneratingDaily,
                        regenerate: { Task { await augmentDaily() } }
                    )
                } else if hasLoadedSummaries {
                    HMEmptyState(
                        title: "今日日报尚未生成",
                        message: "生成后会先显示本地聚合结果；AI 评注始终与主结果分开展示。",
                        icon: "doc.text",
                        tone: .neutral
                    )
                } else if loadError == nil {
                    ProgressView("正在读取今日日报…")
                }
            }

            Section("本周周报") {
                if let s = week, let text = s.summaryText, !text.isEmpty {
                    HMEvidenceTag(
                        tone: .confirmed,
                        text: "本地确定性摘要",
                        systemImage: "lock.doc.fill"
                    )
                    Text(text)
                        .font(.system(.body, design: .rounded))
                        .textSelection(.enabled)
                    Text("起始日：" + s.weekStartDate)
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("生成于 " + formatTime(s.generatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                    llmBlock(
                        text: s.llmText,
                        model: s.llmModel,
                        generatedAt: s.llmGeneratedAt,
                        loading: llmGeneratingWeekly,
                        regenerate: { Task { await augmentWeekly() } }
                    )
                } else if hasLoadedSummaries {
                    HMEmptyState(
                        title: "本周周报尚未生成",
                        message: "生成后会按本周记录汇总；没有记录的项目不会按 0 推断。",
                        icon: "calendar.badge.clock",
                        tone: .neutral
                    )
                } else if loadError == nil {
                    ProgressView("正在读取本周周报…")
                }
            }

            if let err = llmError {
                Section("AI 错误") {
                    HMEditorCallout(
                        title: "AI 评注生成失败",
                        message: "本地摘要仍然有效，失败只影响可选的 AI 评注。",
                        tone: .actionRequired,
                        systemImage: "exclamationmark.triangle.fill",
                        detail: err
                    )
                }
            }

            if let loadError {
                Section {
                    HMInlineRecovery(
                        title: "摘要加载失败",
                        message: "现有摘要没有被修改。可在当前页面重新读取。",
                        technicalDetails: loadError,
                        actionTitle: "重新读取"
                    ) {
                        Task { await refresh() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(HMColors.background)
        .navigationTitle("总结")
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    @ViewBuilder
    private func llmBlock(
        text: String?,
        model: String?,
        generatedAt: Int64?,
        loading: Bool,
        regenerate: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    llmTag
                    llmAction(text: text, loading: loading, regenerate: regenerate)
                }
            } else {
                HStack {
                    llmTag
                    Spacer()
                    llmAction(text: text, loading: loading, regenerate: regenerate)
                }
            }
            if let text, !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                if let model {
                    Text("模型：\(model)" + (generatedAt.map { " · 生成于 \(formatTime($0))" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if !LLMConfig.isConfigured {
                Text("尚未配置 AI 摘要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !LLMConfig.enabled {
                Text("AI 摘要已在设置中关闭。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("点击“生成评注”请求已配置的模型服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("外部边界：只发送本地聚合后的摘要文本，不发送原始样本或设备标识。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(HMColors.estimate.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(HMColors.estimate.opacity(0.28), lineWidth: 1)
        }
    }

    private var llmTag: some View {
                HMEvidenceTag(
                    tone: .estimate,
                    text: "AI 评注 · 可选次级内容",
                    systemImage: "sparkles"
                )
    }

    @ViewBuilder
    private func llmAction(text: String?, loading: Bool, regenerate: @escaping () -> Void) -> some View {
        if loading {
            ProgressView("正在生成评注…")
                .controlSize(.small)
        } else {
            Button {
                regenerate()
            } label: {
                Label(text?.isEmpty == false ? "重新生成" : "生成评注", systemImage: "arrow.clockwise")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(HMColors.estimate)
            .disabled(!LLMConfig.isConfigured)
        }
    }

    private func refresh() async {
        do {
            let todayKey = SummaryGenerator.todayKey()
            let weekKey = SummaryGenerator.currentWeekStartKey()
            let g = generator
            let d = try await g.currentDaily(for: todayKey)
            let w = try await g.currentWeekly(weekStart: weekKey)
            await MainActor.run {
                today = d
                week = w
                loadError = nil
                hasLoadedSummaries = true
            }
        } catch {
            await MainActor.run { loadError = error.localizedDescription }
            AppLogger.shared.error("Summary refresh failed: \(error.localizedDescription)")
        }
    }

    private func generateBoth() async {
        await MainActor.run { generating = true }
        do {
            let g = generator
            let d = try await g.generateDaily()
            let w = try await g.generateWeekly()
            await MainActor.run {
                today = d
                week = w
                generating = false
                loadError = nil
                hasLoadedSummaries = true
            }
            // Default-on LLM: auto-augment if configured.
            if LLMConfig.enabled && LLMConfig.isConfigured {
                Task { await augmentDaily() }
                Task { await augmentWeekly() }
            }
        } catch {
            AppLogger.shared.error("Summary generate failed: \(error.localizedDescription)")
            await MainActor.run {
                generating = false
                loadError = error.localizedDescription
            }
        }
    }

    private func augmentDaily() async {
        await MainActor.run {
            llmGeneratingDaily = true
            llmError = nil
        }
        defer { Task { @MainActor in llmGeneratingDaily = false } }
        do {
            let key = today?.date ?? SummaryGenerator.todayKey()
            _ = try await generator.augmentDailyWithLLM(for: key)
            await refresh()
        } catch {
            await refresh()
            await MainActor.run { llmError = "日报 AI 评注失败：\(error.localizedDescription)" }
            AppLogger.shared.error("LLM daily failed: \(error.localizedDescription)")
        }
    }

    private func augmentWeekly() async {
        await MainActor.run {
            llmGeneratingWeekly = true
            llmError = nil
        }
        defer { Task { @MainActor in llmGeneratingWeekly = false } }
        do {
            let key = week?.weekStartDate ?? SummaryGenerator.currentWeekStartKey()
            _ = try await generator.augmentWeeklyWithLLM(weekStart: key)
            await refresh()
        } catch {
            await refresh()
            await MainActor.run { llmError = "周报 AI 评注失败：\(error.localizedDescription)" }
            AppLogger.shared.error("LLM weekly failed: \(error.localizedDescription)")
        }
    }

    private func formatTime(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
