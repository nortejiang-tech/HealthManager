import SwiftUI
import GRDB

struct SummaryView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @State private var today: DailySummary?
    @State private var week: WeeklySummary?
    @State private var generating: Bool = false

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
                Text("基于本地已采集数据生成；不向云端发送任何数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("今日日报") {
                if let s = today, let text = s.summaryText, !text.isEmpty {
                    Text(text)
                        .font(.system(.body, design: .rounded))
                        .textSelection(.enabled)
                    Text("生成于 " + formatTime(s.generatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
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
                } else {
                    Text("尚未生成。").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("总结")
        .refreshable { await refresh() }
        .task { await refresh() }
    }

    private func refresh() async {
        do {
            let todayKey = SummaryGenerator.todayKey()
            let weekKey = SummaryGenerator.currentWeekStartKey()
            let (d, w) = try await environment.database.asyncRead { db -> (DailySummary?, WeeklySummary?) in
                (try DailySummary.fetchOne(db, key: todayKey),
                 try WeeklySummary.fetchOne(db, key: weekKey))
            }
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
        } catch {
            AppLogger.shared.error("Summary generate failed: \(error.localizedDescription)")
            await MainActor.run { generating = false }
        }
    }

    private func formatTime(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
