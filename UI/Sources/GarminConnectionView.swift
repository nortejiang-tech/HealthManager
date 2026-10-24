import SwiftUI
import UniformTypeIdentifiers

struct GarminConnectionView: View {
    @ObservedObject var manager: GarminSyncManager
    @State private var importing = false
    @State private var error: String?
    @State private var disconnecting = false
    var body: some View {
        List {
            Section("中国区 Garmin Connect") {
                Label(manager.isConfigured ? "已保存 Personal API Key" : "尚未连接", systemImage: "link")
                Text(manager.status).font(.footnote)
                Text("佳明优先，Apple Watch 交叉校验并补全。数据由设备同步至 Connect 后读取。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(manager.isConfigured ? "更换密钥文件" : "导入密钥文件") { importing = true }
                    .disabled(manager.isSyncing)
                Text("支持纯文本或 RTF。导入后密钥仅保存在此设备钥匙串，不进入备份。")
                    .font(.caption).foregroundStyle(.secondary)
                Link("打开中国区密钥设置", destination: URL(string: "https://connect.garmin.cn/app/settings/personalApiToken")!)
                if manager.isConfigured {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Button("立即同步") { Task { await manager.refresh(force: true) } }
                                .disabled(manager.isSyncing || context.date < manager.nextAllowedRefresh)
                            if context.date < manager.nextAllowedRefresh {
                                Text("服务暂缓请求，可在 \(manager.nextAllowedRefresh.formatted(date: .omitted, time: .standard)) 后重试")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if manager.isSyncing { ProgressView() }
                    Button("断开连接", role: .destructive) { disconnecting = true }.disabled(manager.isSyncing)
                }
            }
            if let message = error ?? manager.lastError {
                Section("需要处理") { Text(message).foregroundStyle(HMColors.warning) }
            }
            GarminHealthRows(manager: manager)
        }
        .navigationTitle("佳明健康监测")
        .task { await manager.load() }
        .confirmationDialog("断开后停止拉取，已取得的健康数据保留。", isPresented: $disconnecting) {
            Button("断开连接", role: .destructive) {
                Task { do { try await manager.disconnect() } catch { self.error = (error as? GarminAPIError)?.errorDescription ?? "无法移除本机密钥" } }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .rtf], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 65536 else { error = "密钥文件过大，请选择仅含密钥的文件"; return }
                let data = try Data(contentsOf: url)
                let key: String
                if url.pathExtension.lowercased() == "rtf" {
                    key = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
                } else {
                    guard let text = String(data: data, encoding: .utf8) else { error = "请使用 UTF-8 文本或 RTF 文件"; return }
                    key = text
                }
                Task {
                    do { try await manager.importKey(key); error = nil; await manager.refresh(force: true) }
                    catch { self.error = (error as? GarminAPIError)?.errorDescription ?? "密钥导入失败，请检查文件内容和钥匙串权限" }
                }
            } catch { self.error = "无法读取密钥文件，请重新选择" }
        }
    }
}

struct GarminHealthRows: View {
    @ObservedObject var manager: GarminSyncManager
    var body: some View {
        Section("Garmin 持续健康") {
            ForEach(GarminMetric.allCases, id: \.self) { metric in
                let selection = GarminPresentation(metric: metric, records: manager.records)
                let record = selection.displayed
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(metric.title)
                        Spacer()
                        Text(record?.payload?.primary.map { String(format: "%.0f%@", $0, metric.unit.isEmpty ? "" : " \(metric.unit)") } ?? "暂无数据")
                            .fontWeight(.semibold)
                    }
                    if let record {
                        Text("\(record.date) · \(selection.status)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let time = record.payload?.observedAt {
                            Text("测量：\(Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("最近请求：\((selection.latestAttempt?.lastAttemptAt ?? record.lastAttemptAt).formatted(date: .abbreviated, time: .shortened))\(selection.latestAttempt?.state == "noData" ? " · 云端暂无可用数据" : selection.latestAttempt?.state == "error" ? " · 请求未完成" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                        if metric == .sleep, record.payload?.labels["confirmed"] == "false" {
                            Text("睡眠窗口尚未确认").font(.caption)
                        }
                        if metric == .sleep, record.payload?.primary == nil {
                            if record.payload?.values.keys.contains(where:{ $0.hasPrefix("score.") }) == true {
                                Text("已返回评分分项，总分字段待核对").font(.caption)
                            } else if record.payload?.values["sleepTimeSeconds"] != nil {
                                Text("已有睡眠时长，官方评分尚未提供").font(.caption)
                            }
                        }
                    } else { Text(manager.isConfigured ? "等待同步或设备形成记录" : "连接中国区 Personal API 后读取").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4)
            }
            HMHelpText(text: "Garmin 夜间 HRV 与 Apple SDNN 分开保存；分段 Body Battery 不是实时流；压力展示每日摘要。", title: "指标口径")
        }
    }
}

struct GarminTrainingPanel: View {
    @ObservedObject var manager: GarminSyncManager
    var body: some View {
        TrainingPanel(title: "持续健康", icon: "heart.text.square") {
            GarminHealthRows(manager: manager)
            GarminReadinessAvailabilityView()
            NavigationLink("连接管理与设置") { SettingsView() }
                .font(.subheadline)
        }.task { await manager.load() }
    }
}
