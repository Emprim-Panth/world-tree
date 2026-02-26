import Foundation
import GRDB

/// Manages canvas-specific schema migrations.
/// Only creates new canvas_* tables — never touches existing cortana-core tables.
enum MigrationManager {

    static func migrate(_ dbPool: DatabasePool) throws {
        // Disable deferred FK checks — the database is shared with cortana-core
        // and may have orphaned rows in tables we don't own (sessions, messages, summaries).
        // World Tree only controls canvas_* tables.
        var migrator = DatabaseMigrator().disablingDeferredForeignKeyChecks()

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
            // Guard: messages table is owned by cortana-core and may not exist in standalone databases
            let hasMessages = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages'
                """) ?? false
            if hasMessages {
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
            }
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

        // Migration 10: Index on fork_from_message_id for branchesFromMessage() performance
        migrator.registerMigration("v10_fork_message_index") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_branches_fork_message ON canvas_branches(fork_from_message_id)")
        }

        // Migration 11: Standalone core tables — sessions + messages
        // In cortana deployments these tables are owned by cortana-core.
        // On standalone World Tree installs they must be created here.
        // CREATE TABLE IF NOT EXISTS is safe for both cases.
        migrator.registerMigration("v11_standalone_core_tables") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    terminal_id TEXT,
                    working_directory TEXT,
                    description TEXT,
                    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_timestamp ON messages(session_id, timestamp)")

            // FTS5 full-text search index — used by MessageStore.searchMessages()
            // Guard: fts5 may not be available on all SQLite builds
            let hasFTS5 = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'messages_fts'
                """) ?? false) ?? false
            if !hasFTS5 {
                try? db.execute(sql: """
                    CREATE VIRTUAL TABLE messages_fts USING fts5(
                        content,
                        content=messages,
                        content_rowid=id
                    )
                    """)
            }
        }

        // Migration 12: FTS5 with porter tokenizer + sync triggers
        // The v11 FTS5 table has no tokenizer (defaults to unicode61, no stemming)
        // and no sync triggers (index goes stale immediately after creation).
        // All operations must succeed as a unit — partial FTS creates a corrupt index.
        migrator.registerMigration("v12_fts5_porter_triggers") { db in
            // Drop the old FTS table and recreate with porter stemming
            try db.execute(sql: "DROP TABLE IF EXISTS messages_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    content,
                    content=messages,
                    content_rowid=id,
                    tokenize='porter unicode61'
                )
                """)

            // Sync triggers — keep FTS index in lockstep with messages table
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content) VALUES('delete', old.id, old.content);
                    INSERT INTO messages_fts(rowid, content) VALUES (new.id, new.content);
                END
                """)

            // Rebuild index from all existing messages
            try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
        }

        // Migration 13: Dispatch queue for Agent SDK programmatic dispatch
        migrator.registerMigration("v13_dispatches") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_dispatches (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    branch_id TEXT,
                    message TEXT NOT NULL,
                    model TEXT,
                    status TEXT NOT NULL DEFAULT 'queued'
                        CHECK(status IN ('queued','running','completed','failed','cancelled','interrupted')),
                    working_directory TEXT NOT NULL,
                    origin TEXT NOT NULL DEFAULT 'background',
                    result_text TEXT,
                    result_tokens_in INTEGER,
                    result_tokens_out INTEGER,
                    error TEXT,
                    cli_session_id TEXT,
                    started_at TIMESTAMP,
                    completed_at TIMESTAMP,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_dispatches_project ON canvas_dispatches(project)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_dispatches_status ON canvas_dispatches(status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_dispatches_created ON canvas_dispatches(created_at)")
        }

        // Migration 14: Per-project metrics for Command Center
        migrator.registerMigration("v14_project_metrics") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_project_metrics (
                    project TEXT PRIMARY KEY,
                    total_dispatches INTEGER DEFAULT 0,
                    successful_dispatches INTEGER DEFAULT 0,
                    failed_dispatches INTEGER DEFAULT 0,
                    total_tokens_in INTEGER DEFAULT 0,
                    total_tokens_out INTEGER DEFAULT 0,
                    total_duration_seconds REAL DEFAULT 0,
                    last_activity_at TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
        }

        // Migration 15: Intelligence Upgrade — recognize tables created by Python scripts
        // These are created by the Python memory system but World Tree needs to read them.
        // CREATE TABLE IF NOT EXISTS ensures safety whether Python or World Tree runs first.
        migrator.registerMigration("v15_intelligence_tables") { db in
            // Conversation archive (compressed session summaries)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_archive (
                    session_id TEXT PRIMARY KEY,
                    project TEXT,
                    compressed_summary TEXT NOT NULL,
                    key_entities TEXT,
                    key_decisions TEXT,
                    key_errors TEXT,
                    files_touched TEXT,
                    duration_minutes REAL,
                    message_count INTEGER,
                    token_estimate INTEGER,
                    compression_ratio REAL,
                    full_transcript_path TEXT,
                    archived_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_ca_project ON conversation_archive(project)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_ca_archived ON conversation_archive(archived_at)")

            // Knowledge versions (version history for knowledge entries)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS knowledge_versions (
                    id TEXT PRIMARY KEY,
                    knowledge_id TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    rationale TEXT,
                    diff_from_previous TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(knowledge_id, version)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_kv_knowledge ON knowledge_versions(knowledge_id)")

            // Crew handoffs (agent-to-agent task handoff)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS crew_handoffs (
                    id TEXT PRIMARY KEY,
                    from_agent TEXT NOT NULL,
                    to_agent TEXT NOT NULL,
                    task_summary TEXT NOT NULL,
                    context TEXT,
                    deliverables TEXT,
                    requirements TEXT,
                    status TEXT DEFAULT 'pending',
                    result TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP
                )
                """)

            // FTS5 for conversation archive search
            let hasCaFts = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'conversation_archive_fts'
                """) ?? false) ?? false
            if !hasCaFts {
                try? db.execute(sql: """
                    CREATE VIRTUAL TABLE conversation_archive_fts USING fts5(
                        compressed_summary, key_entities, key_decisions,
                        content='conversation_archive',
                        content_rowid='rowid'
                    )
                    """)
            }

            // FTS5 for knowledge graph nodes
            let hasCgFts = (try? Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'cg_nodes_fts'
                """) ?? false) ?? false
            if !hasCgFts {
                // Only create if cg_nodes exists (it's a cortana-core table)
                let hasCgNodes = try Bool.fetchOne(db, sql: """
                    SELECT COUNT(*) > 0 FROM sqlite_master
                    WHERE type = 'table' AND name = 'cg_nodes'
                    """) ?? false
                if hasCgNodes {
                    try? db.execute(sql: """
                        CREATE VIRTUAL TABLE cg_nodes_fts USING fts5(
                            label, content,
                            content='cg_nodes',
                            content_rowid='rowid'
                        )
                        """)
                }
            }
        }

        try migrator.migrate(dbPool)
    }
}
