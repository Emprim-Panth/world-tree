import Foundation
import GRDB

/// Manages canvas-specific schema migrations.
/// Only creates new canvas_* tables — never touches existing cortana-core tables.
enum MigrationManager {

    static func migrate(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        // Migration 1: Canvas tree & branch tables
        migrator.registerMigration("v1_canvas_tables") { db in
            // Tree container
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_trees (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    project TEXT,
                    working_directory TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    archived INTEGER DEFAULT 0
                )
                """)

            // Branch overlay on existing sessions
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_branches (
                    id TEXT PRIMARY KEY,
                    tree_id TEXT NOT NULL REFERENCES canvas_trees(id),
                    session_id TEXT REFERENCES sessions(id),
                    parent_branch_id TEXT REFERENCES canvas_branches(id),
                    fork_from_message_id INTEGER REFERENCES messages(id),
                    branch_type TEXT NOT NULL DEFAULT 'conversation'
                        CHECK(branch_type IN ('conversation','implementation','exploration')),
                    title TEXT,
                    status TEXT NOT NULL DEFAULT 'active'
                        CHECK(status IN ('active','completed','archived','failed')),
                    summary TEXT,
                    model TEXT,
                    daemon_task_id TEXT,
                    context_snapshot TEXT,
                    collapsed INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            // Indexes for tree traversal
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_branches_tree ON canvas_branches(tree_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_branches_parent ON canvas_branches(parent_branch_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_branches_session ON canvas_branches(session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_branches_daemon_task ON canvas_branches(daemon_task_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_trees_project ON canvas_trees(project)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_trees_updated ON canvas_trees(updated_at)")

            // Branch tags for organization
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_branch_tags (
                    branch_id TEXT NOT NULL REFERENCES canvas_branches(id),
                    tag TEXT NOT NULL,
                    PRIMARY KEY (branch_id, tag)
                )
                """)
        }

        // Migration 2: API conversation state + token tracking
        migrator.registerMigration("v2_api_state") { db in
            // Serialized API conversation state per session
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_api_state (
                    session_id TEXT PRIMARY KEY,
                    api_messages TEXT NOT NULL,
                    system_prompt TEXT NOT NULL,
                    token_usage TEXT,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            // Per-turn token usage tracking
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_token_usage (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    branch_id TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL DEFAULT 0,
                    output_tokens INTEGER NOT NULL DEFAULT 0,
                    cache_hit_tokens INTEGER NOT NULL DEFAULT 0,
                    recorded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_token_usage_session ON canvas_token_usage(session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_token_usage_date ON canvas_token_usage(recorded_at)")
        }

        try migrator.migrate(dbPool)
    }
}
