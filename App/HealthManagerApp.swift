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
        }
        .onChange(of: scenePhase) {
            // Manual-sync auto-ack: if a manual sync is parked waiting for the user to come
            // back from an external app (Garmin / 米家), resume it. Brief delay gives
            // HealthKit a moment to ingest the external app's writes before pass 2.
            guard scenePhase == .active,
                  environment.syncEngine.manualSyncPrompt != nil else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                environment.syncEngine.acknowledgeExternalSyncDone()
            }
        }
    }
}
