import Foundation
import GRDB

/// Long-lived wrapper around the SQLite store. One file per app install at
/// `Library/Application Support/HealthManager/health.sqlite`.
///
/// `@unchecked Sendable`: the only stored properties are an immutable `let pool` (DatabasePool
/// is thread-safe and Sendable) and an immutable `let databasePath`. No mutation after init.
final class DatabaseManager: @unchecked Sendable {

    let pool: DatabasePool
    let databasePath: String

    private init(pool: DatabasePool, path: String) {
        self.pool = pool
        self.databasePath = path
    }

    /// In-memory database for unit tests. Migrations are applied so the schema mirrors prod.
    static func makeInMemoryForTesting() -> DatabaseManager {
        do {
            var config = Configuration()
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON;")
            }
            // GRDB on iOS only exposes DatabaseQueue for in-memory; wrap it in a
            // DatabasePool-shaped API would change call sites. Use a temp-file pool
            // instead so the real read/write methods still go through DatabasePool.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("hm-test-\(UUID().uuidString).sqlite")
            let pool = try DatabasePool(path: tmp.path, configuration: config)
            let manager = DatabaseManager(pool: pool, path: tmp.path)
            try Migrations.run(on: pool)
            return manager
        } catch {
            fatalError("Failed to create in-memory test DB: \(error)")
        }
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

    /// Async variant — dispatches the synchronous GRDB read to a detached task so the
    /// caller's actor (especially MainActor) isn't blocked while SQLite executes.
    /// Use from UI code paths instead of `read`.
    func asyncRead<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let pool = self.pool
        return try await Task.detached(priority: .userInitiated) {
            try pool.read(block)
        }.value
    }

    /// Async variant for writes; same rationale as `asyncRead`.
    @discardableResult
    func asyncWrite<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        let pool = self.pool
        return try await Task.detached(priority: .userInitiated) {
            try pool.write(block)
        }.value
    }
}
