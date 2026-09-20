import SwiftUI

@main
struct HealthManagerApp: App {
    @StateObject private var environment = AppEnvironment.shared
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    init() {
        AppEnvironment.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.syncEngine)
                .environmentObject(environment.healthKitManager)
                .environmentObject(environment.backupManager)
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else {
                environment.applicationDidBecomeInactive()
                // 退后台：自动导出备份包（已配置位置时）。
                if scenePhase == .background {
                    Task { await environment.applicationDidEnterBackground() }
                }
                return
            }

            // Manual-sync auto-ack: if a manual sync is parked waiting for the user to come
            // back from an external app (Garmin / 米家), resume it. Brief delay gives
            // HealthKit a moment to ingest the external app's writes before pass 2.
            if environment.syncEngine.manualSyncPrompt != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    environment.syncEngine.acknowledgeExternalSyncDone()
                    await environment.applicationDidBecomeActive()
                }
                return
            }
            Task { await environment.applicationDidBecomeActive() }
        }
    }
}
