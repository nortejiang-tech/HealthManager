import Foundation
import GRDB

/// Long-lived wrapper around the SQLite store. One file per app install at
/// `Library/Application Support/HealthManager/health.sqlite`.
final class DatabaseManager {

    let pool: DatabasePool
    let databasePath: String

    private init(pool: DatabasePool, path: String) {
        self.pool = pool
        self.databasePath = path
    }

    static func makeDefault() -> DatabaseManager {
        do {
            let fm = FileManager.default
            let supportDir = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("HealthManager", isDirectory: true)
            if !fm.fileExists(atPath: supportDir.path) {
                try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            }
            let dbURL = supportDir.appendingPathComponent("health.sqlite")

            var config = Configuration()
            config.prepareDatabase { db in
                // WAL mode is enabled by DatabasePool automatically; keep busy timeout generous
                // for background-task contention.
                try db.execute(sql: "PRAGMA busy_timeout = 5000;")
                try db.execute(sql: "PRAGMA foreign_keys = ON;")
            }

            let pool = try DatabasePool(path: dbURL.path, configuration: config)
            let manager = DatabaseManager(pool: pool, path: dbURL.path)
            try Migrations.run(on: pool)
            AppLogger.shared.database.info("DB ready at \(dbURL.path, privacy: .public)")
            return manager
        } catch {
            // The DB is the single point of failure for the entire app. Crashing early surfaces
            // the problem instead of letting downstream features fail silently.
            fatalError("Failed to initialise DatabaseManager: \(error)")
        }
    }

    // MARK: - Convenience accessors

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    @discardableResult
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.write(block)
    }
}
