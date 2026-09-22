import SwiftUI

struct HealthBridgeSettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var bridge: HealthBridgeManager
    @State private var showFolder = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Text("将近一年健康数据和已有饮食、用药记录同步给 Mac 上的健康管家。Agent 可读取明细；修改仍在本 App 完成。")
                Button("选择 iCloud 同步文件夹…") { showFolder=true }.disabled(bridge.isBusy)
                LabeledContent("位置",value:bridge.locationName)
                Toggle("同步给健康管家",isOn:Binding(get:{bridge.enabled},set:{ value in
                    bridge.setEnabled(value)
                    if bridge.enabled { Task { await bridge.captureAndSync(syncEngine:environment.syncEngine) } }
                })).disabled(bridge.isBusy)
            } footer: {
                Text("建议选择 iCloud Drive / Health manager；App 会创建 HealthBridgeSync 子目录。现有备份保持独立。传输文件由 iCloud 同步，云模型可能接收 Agent 查询结果；不包含照片、密钥和服务配置。")
            }
            Section("同步状态") {
                Text(bridge.status).accessibilityIdentifier("bridge.syncStatus")
                if bridge.isBusy { ProgressView() }
                if let issue = bridge.lastError ?? error {
                    Text(issue)
                        .foregroundStyle(HMColors.actionRequired)
                        .textSelection(.enabled)
                }
                Button("立即同步 / 检查 Mac 回执") { Task { await bridge.exportIfConfigured() } }
                    .disabled(!bridge.enabled || bridge.isBusy)
                Text("文件写出不等于 Mac 已收到。iCloud、锁屏和后台调度可能延迟；需要最新数据时打开本 App 同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("历史数据") {
                DatePicker("回补起点",selection:$bridge.historyStart,in:...Date(),displayedComponents:.date)
                Button("采集历史并重建同步快照") { Task { await bridge.captureAndSync(syncEngine:environment.syncEngine) } }
                    .disabled(!bridge.enabled || bridge.isBusy || environment.syncEngine.isBusy)
                Button("用已有本地数据重建 Mac 副本") { Task { await bridge.rebuild() } }
                    .disabled(!bridge.enabled || bridge.isBusy)
                Text("历史范围表示请求范围，不保证各指标都有记录。未读到数据不能区分没有记录与未授予读取权限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("健康管家同步")
        .sheet(isPresented:$showFolder) {
            FolderPicker { url in
                do { try bridge.selectFolder(url);error=nil } catch { self.error=error.localizedDescription }
            }
        }
    }
}
