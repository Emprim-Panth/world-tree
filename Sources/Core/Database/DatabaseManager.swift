import Foundation
import GRDB

/// Singleton database manager for conversations.db
/// Matches cortana-core PRAGMA configuration exactly:
/// - WAL mode for concurrent read/write
/// - Foreign keys enabled
/// - 5 second busy timeout
///
/// Database is local at ~/.cortana/claude-memory/conversations.db.
/// Aggressive WAL checkpointing keeps file size bounded.
@MainActor
final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbPool: DatabasePool?

    /// WAL checkpoint timer — runs every 30 seconds to keep WAL size bounded
    /// and minimize risk of stale WAL files on Dropbox.
    private var checkpointTimer: Timer?

    private init() {}

    /// Opens the database at the configured path (local, with fallback)
    func setup() throws {
        let path = resolveDatabasePath()

        var config = Configuration()
        config.prepareDatabase { db in
            // Match cortana-core/src/db/index.ts exactly
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
            // Checkpoint after every 100 pages (~400KB) to keep WAL small
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 100")
            // NORMAL sync is safe with WAL mode and reduces I/O overhead
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }

        dbPool = try DatabasePool(path: path, configuration: config)

        // Run canvas-specific migrations
        try MigrationManager.migrate(dbPool!)

        // Start periodic WAL checkpoint to keep file size bounded
        startCheckpointTimer()
    }

    /// Resolves database path — priority order:
    /// 1. User override from Settings (UserDefaults "databasePath") if the file exists
    /// 2. Local claude-memory path (default)
    /// 3. Fallback to ~/.cortana/cortana.db
    private func resolveDatabasePath() -> String {
        // User-configured override (Settings → Connection tab)
        if let override = UserDefaults.standard.string(forKey: "databasePath"),
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }

        let primaryPath = AppConstants.databasePath
        if FileManager.default.fileExists(atPath: primaryPath) {
            return primaryPath
        }

        // Primary not available — fall back to cortana.db
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = "\(home)/.cortana/cortana.db"
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }

        // Neither exists — create at primary path (GRDB will create the file)
        let dir = (primaryPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return primaryPath
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

    /// Async read — runs on GRDB's reader queue, NOT on MainActor.
    /// Use this for expensive queries to avoid blocking the main thread.
    func asyncRead<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try await dbPool.read(block)
    }

    /// Async write — runs on GRDB's writer queue, NOT on MainActor.
    func asyncWrite<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let dbPool else { throw DatabaseError.notConnected }
        return try await dbPool.write(block)
    }

    // MARK: - WAL Checkpoint Management

    /// Periodically checkpoint WAL to keep file size bounded.
    private func startCheckpointTimer() {
        checkpointTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performCheckpoint()
            }
        }
    }

    private func performCheckpoint() {
        guard let dbPool else { return }
        Task.detached {
            do {
                try await dbPool.write { db in
                    // PASSIVE checkpoint — does not block readers/writers.
                    // Moves committed WAL pages back to the main database file.
                    try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
                }
            } catch {
                await MainActor.run {
                    wtLog("[DatabaseManager] WAL checkpoint failed: \(error)")
                }
            }
        }
    }

    func stopCheckpointTimer() {
        checkpointTimer?.invalidate()
        checkpointTimer = nil
    }

    /// Replace the database pool with a test database. Used by unit tests only.
    /// Stops the checkpoint timer since test databases don't need it.
    /// Pass nil to disconnect (for tearDown).
    func setDatabasePoolForTesting(_ pool: DatabasePool?) {
        stopCheckpointTimer()
        dbPool = pool
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
