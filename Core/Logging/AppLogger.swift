import Foundation
import os.log

/// Thin wrapper over Apple's unified logging. Centralised so callers don't repeat the subsystem.
final class AppLogger {
    static let shared = AppLogger()

    let app = Logger(subsystem: "com.norte.HealthManager", category: "app")
    let healthkit = Logger(subsystem: "com.norte.HealthManager", category: "healthkit")
    let database = Logger(subsystem: "com.norte.HealthManager", category: "database")
    let sync = Logger(subsystem: "com.norte.HealthManager", category: "sync")
    let bg = Logger(subsystem: "com.norte.HealthManager", category: "background")

    func info(_ message: String) { app.info("\(message, privacy: .public)") }
    func warn(_ message: String) { app.warning("\(message, privacy: .public)") }
    func error(_ message: String) { app.error("\(message, privacy: .public)") }
}
