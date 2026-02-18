import Foundation
import GRDB

/// Singleton database manager for conversations.db
/// Matches cortana-core PRAGMA configuration exactly:
/// - WAL mode for concurrent read/write
/// - Foreign keys enabled
/// - 5 second busy timeout
@MainActor
final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool?

    private init() {}

    /// Opens the database at the configured path (Dropbox-synced, with fallback)
    func setup() throws {
        let path = resolveDatabasePath()

        var config = Configuration()
        config.prepareDatabase { db in
            // Match cortana-core/src/db/index.ts exactly
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }

        dbPool = try DatabasePool(path: path, configuration: config)

        // Run canvas-specific migrations
        try MigrationManager.migrate(dbPool!)
    }

    /// Resolves database path — priority order:
    /// 1. User override from Settings (UserDefaults "databasePath") if the file exists
    /// 2. Dropbox-synced path (default)
    /// 3. Local fallback (~/.cortana/cortana.db)
    private func resolveDatabasePath() -> String {
        // User-configured override (Settings → Connection tab)
        if let override = UserDefaults.standard.string(forKey: "databasePath"),
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let dropbox = CortanaConstants.dropboxDatabasePath
        if FileManager.default.fileExists(atPath: dropbox) {
            return dropbox
        }

        let fallback = CortanaConstants.fallbackDatabasePath
        let dir = (fallback as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return fallback
    }

    /// Read-only access (preferred for browsing)
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try dbPool.read(block)
    }

    /// Read-write access (for mutations)
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try dbPool.write(block)
    }
}

enum DatabaseError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Database not connected. Call DatabaseManager.setup() first."
        }
    }
}
