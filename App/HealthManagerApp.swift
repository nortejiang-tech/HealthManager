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
            guard scenePhase == .active else { return }

            // Manual-sync auto-ack: if a manual sync is parked waiting for the user to come
            // back from an external app (Garmin / 米家), resume it. Brief delay gives
            // HealthKit a moment to ingest the external app's writes before pass 2.
            if environment.syncEngine.manualSyncPrompt != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    environment.syncEngine.acknowledgeExternalSyncDone()
                }
                return
            }

            // Auto incremental sync on every foreground entry. Skip if the user hasn't
            // completed onboarding (no point firing HK queries that will all auth-deny).
            // `runIncremental` itself drops calls when isBusy, so rapid app-switching is safe.
            let gate = environment.healthKitManager.authorizationGate
            guard gate == .granted || gate == .partiallyGranted else { return }
            Task { await environment.syncEngine.runIncremental(trigger: .timer) }
        }
    }
}
