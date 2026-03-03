import Foundation
import GRDB

// MARK: - LocalDatabase
//
// SQLite cache for offline message and tree/branch data.
// DB file: <Documents>/worldtree-cache.db  (WAL mode)
//
// Tables
//   cached_messages  – one row per message; keyed by id + branchId
//   cached_branches  – BranchSummary snapshots
//   cached_trees     – TreeSummary snapshots
//
// All public API is @MainActor because callers (WorldTreeStore) are @MainActor.
// DB writes happen on a background writer queue inside GRDB — @MainActor just
// means the call-site doesn't need to hop threads before calling us.

final class LocalDatabase {

    // MARK: - Singleton

    static let shared = LocalDatabase()

    // MARK: - Storage

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    private init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("worldtree-cache.db")

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        do {
            dbQueue = try DatabaseQueue(path: url.path, configuration: config)
            try createTablesIfNeeded()
        } catch {
            // If DB setup fails we degrade gracefully — callers check for cached data
            // and fall back to empty arrays, so this is non-fatal.
            fatalError("[LocalDatabase] Failed to open SQLite: \(error)")
        }
    }

    // MARK: - Schema

    private func createTablesIfNeeded() throws {
        try dbQueue.write { db in
            // Messages cache
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cached_messages (
                    id          TEXT NOT NULL,
                    branch_id   TEXT NOT NULL,
                    role        TEXT NOT NULL,
                    content     TEXT NOT NULL,
                    created_at  TEXT NOT NULL,
                    PRIMARY KEY (id, branch_id)
                )
            """)

            // Branches cache
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cached_branches (
                    id          TEXT PRIMARY KEY NOT NULL,
                    tree_id     TEXT NOT NULL,
                    title       TEXT,
                    status      TEXT NOT NULL,
                    branch_type TEXT NOT NULL,
                    created_at  TEXT NOT NULL,
                    updated_at  TEXT NOT NULL
                )
            """)

            // Trees cache
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cached_trees (
                    id            TEXT PRIMARY KEY NOT NULL,
                    name          TEXT NOT NULL,
                    project       TEXT,
                    updated_at    TEXT NOT NULL,
                    message_count INTEGER NOT NULL DEFAULT 0
                )
            """)

            // Index so per-branch message queries stay fast
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_cached_messages_branch
                ON cached_messages (branch_id)
            """)

            // Index so per-tree branch queries stay fast
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_cached_branches_tree
                ON cached_branches (tree_id)
            """)
        }
    }

    // MARK: - Messages

    /// Upsert a single message into the cache.
    /// `branchId` is required because Message itself doesn't carry it.
    @MainActor
    func upsertMessage(_ message: Message, branchId: String) {
        Task.detached(priority: .utility) { [dbQueue] in
            try? dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO cached_messages (id, branch_id, role, content, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT (id, branch_id) DO UPDATE SET
                            role       = excluded.role,
                            content    = excluded.content,
                            created_at = excluded.created_at
                    """,
                    arguments: [message.id, branchId, message.role, message.content, message.createdAt]
                )
            }
        }
    }

    /// Replace all cached messages for a branch with the provided list.
    /// Called on `messages_list` events to keep the cache in sync with server truth.
    @MainActor
    func replaceMessages(_ messages: [Message], branchId: String) {
        Task.detached(priority: .utility) { [dbQueue] in
            try? dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM cached_messages WHERE branch_id = ?",
                    arguments: [branchId]
                )
                for message in messages {
                    try db.execute(
                        sql: """
                            INSERT INTO cached_messages (id, branch_id, role, content, created_at)
                            VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [message.id, branchId, message.role, message.content, message.createdAt]
                    )
                }
            }
        }
    }

    /// Load cached messages for a branch, ordered oldest-first.
    /// Returns an empty array when nothing is cached (no throw — caller treats empty as "nothing cached").
    @MainActor
    func loadMessages(branchId: String) -> [Message] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, role, content, created_at
                    FROM cached_messages
                    WHERE branch_id = ?
                    ORDER BY created_at ASC
                """,
                arguments: [branchId]
            )
            return rows.map { row in
                Message(
                    id: row["id"],
                    role: row["role"],
                    content: row["content"],
                    createdAt: row["created_at"]
                )
            }
        }) ?? []
    }

    // MARK: - Branches

    /// Upsert a list of branches.
    @MainActor
    func replaceBranches(_ branches: [BranchSummary], treeId: String) {
        Task.detached(priority: .utility) { [dbQueue] in
            try? dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM cached_branches WHERE tree_id = ?",
                    arguments: [treeId]
                )
                for b in branches {
                    try db.execute(
                        sql: """
                            INSERT INTO cached_branches
                                (id, tree_id, title, status, branch_type, created_at, updated_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [b.id, b.treeId, b.title, b.status, b.branchType, b.createdAt, b.updatedAt]
                    )
                }
            }
        }
    }

    /// Load cached branches for a tree, ordered by created_at ascending.
    @MainActor
    func loadBranches(treeId: String) -> [BranchSummary] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, tree_id, title, status, branch_type, created_at, updated_at
                    FROM cached_branches
                    WHERE tree_id = ?
                    ORDER BY created_at ASC
                """,
                arguments: [treeId]
            )
            return rows.map { row in
                BranchSummary(
                    id: row["id"],
                    treeId: row["tree_id"],
                    title: row["title"],
                    status: row["status"],
                    branchType: row["branch_type"],
                    createdAt: row["created_at"],
                    updatedAt: row["updated_at"]
                )
            }
        }) ?? []
    }

    // MARK: - Trees

    /// Replace the full tree list cache.
    @MainActor
    func replaceTrees(_ trees: [TreeSummary]) {
        Task.detached(priority: .utility) { [dbQueue] in
            try? dbQueue.write { db in
                try db.execute(sql: "DELETE FROM cached_trees")
                for t in trees {
                    try db.execute(
                        sql: """
                            INSERT INTO cached_trees (id, name, project, updated_at, message_count)
                            VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [t.id, t.name, t.project, t.updatedAt, t.messageCount]
                    )
                }
            }
        }
    }

    /// Load all cached trees, ordered by updated_at descending (most recently active first).
    @MainActor
    func loadTrees() -> [TreeSummary] {
        (try? dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, project, updated_at, message_count
                    FROM cached_trees
                    ORDER BY updated_at DESC
                """
            )
            return rows.map { row in
                TreeSummary(
                    id: row["id"],
                    name: row["name"],
                    project: row["project"],
                    updatedAt: row["updated_at"],
                    messageCount: row["message_count"]
                )
            }
        }) ?? []
    }
}
