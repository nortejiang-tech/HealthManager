import SwiftUI

@main
struct HealthManagerApp: App {
    @StateObject private var environment = AppEnvironment.shared

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
    }
}
