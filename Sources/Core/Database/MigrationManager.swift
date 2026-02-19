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
                    fork_from_message_id TEXT REFERENCES messages(id),
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

        // Migration 3: Background job queue
        migrator.registerMigration("v3_job_queue") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_jobs (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL DEFAULT 'background_run',
                    command TEXT NOT NULL,
                    working_directory TEXT NOT NULL,
                    branch_id TEXT,
                    status TEXT NOT NULL DEFAULT 'queued'
                        CHECK(status IN ('queued','running','completed','failed','cancelled')),
                    output TEXT,
                    error TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_jobs_status ON canvas_jobs(status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_jobs_branch ON canvas_jobs(branch_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_jobs_created ON canvas_jobs(created_at)")
        }

        // Migration 4: Project cache for scanner results
        migrator.registerMigration("v4_project_cache") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_cache (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    path TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    type TEXT NOT NULL DEFAULT 'unknown',
                    git_branch TEXT,
                    git_dirty INTEGER NOT NULL DEFAULT 0,
                    last_modified TIMESTAMP,
                    last_scanned TIMESTAMP,
                    readme TEXT
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_project_cache_path ON project_cache(path)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_project_cache_scanned ON project_cache(last_scanned)")
        }

        // Migration 5: CLI session mapping for provider resume support
        migrator.registerMigration("v5_cli_sessions") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_cli_sessions (
                    canvas_session_id TEXT PRIMARY KEY,
                    cli_session_id TEXT NOT NULL,
                    provider TEXT NOT NULL DEFAULT 'claude-code',
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
        }

        // Migration 6: Event log for observability
        migrator.registerMigration("v6_events") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    branch_id TEXT NOT NULL,
                    session_id TEXT,
                    event_type TEXT NOT NULL,
                    event_data TEXT,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_branch ON canvas_events(branch_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_type ON canvas_events(event_type)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_timestamp ON canvas_events(timestamp)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_events_branch_time ON canvas_events(branch_id, timestamp)")

            // Ensure messages table has session_id index (DB quick win)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
        }

        // Migration 7: Context checkpoints for session rotation
        migrator.registerMigration("v7_context_checkpoints") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_context_checkpoints (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    branch_id TEXT NOT NULL,
                    summary TEXT NOT NULL,
                    estimated_tokens_at_rotation INTEGER,
                    message_count_at_rotation INTEGER,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_checkpoints_session ON canvas_context_checkpoints(session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_checkpoints_branch ON canvas_context_checkpoints(branch_id)")
        }

        // Migration 8: tmux session persistence per branch
        migrator.registerMigration("v8_tmux_sessions") { db in
            try db.execute(sql: """
                ALTER TABLE canvas_branches ADD COLUMN tmux_session_name TEXT
                """)
        }

        // Migration 9: Screenshots table
        migrator.registerMigration("v9_screenshots") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_screenshots (
                    id TEXT PRIMARY KEY,
                    branch_id TEXT,
                    file_path TEXT NOT NULL,
                    target TEXT NOT NULL DEFAULT 'simulator',
                    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_screenshots_branch ON canvas_screenshots(branch_id)")
        }

        try migrator.migrate(dbPool)
    }
}
