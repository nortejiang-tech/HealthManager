import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var today: DailySummary?
    @State private var week: WeeklySummary?
    @State private var generating: Bool = false
    @State private var llmGeneratingDaily: Bool = false
    @State private var llmGeneratingWeekly: Bool = false
    @State private var llmError: String?

    private var generator: SummaryGenerator { SummaryGenerator(database: environment.database) }

    var body: some View {
        List {
            Section {
                Button {
                    Task { await generateBoth() }
                } label: {
                    Label(generating ? "生成中…" : "重新生成日报 + 周报", systemImage: "sparkles")
                }
                .disabled(generating)
                Text("本地确定性聚合，不联网。若已配置 AI 摘要，会在每段下方追加 LLM 评注。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !LLMConfig.isConfigured, LLMConfig.enabled {
                Section {
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
                } else {
                    Text("尚未生成。点击上方按钮。").foregroundStyle(.secondary)
                }
            }

            Section("本周周报") {
                if let s = week, let text = s.summaryText, !text.isEmpty {
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
                } else {
                    Text("尚未生成。").foregroundStyle(.secondary)
                }
            }

            if let err = llmError {
                Section("AI 错误") {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("AI 评注", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                Spacer()
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        regenerate()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.small)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!LLMConfig.isConfigured)
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
                Text("点击 ↻ 生成评注。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            }
        } catch {
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
            }
            // Default-on LLM: auto-augment if configured.
            if LLMConfig.enabled && LLMConfig.isConfigured {
                Task { await augmentDaily() }
                Task { await augmentWeekly() }
            }
        } catch {
            AppLogger.shared.error("Summary generate failed: \(error.localizedDescription)")
            await MainActor.run { generating = false }
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
