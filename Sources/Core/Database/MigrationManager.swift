import Foundation
import GRDB
import os.log

private let migrationLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "Migration")

/// Manages canvas-specific schema migrations.
/// Only creates new canvas_* tables — never touches existing cortana-core tables.
enum MigrationManager {

    /// Attempts to copy the database file as a pre-migration backup.
    /// Best-effort: logs a warning if the backup fails but does not block migration.
    private static func backupDatabaseFile(at pool: DatabasePool) {
        do {
            let dbPath = pool.path
            let backupPath = dbPath + ".pre-migration-backup"
            let fm = FileManager.default
            // Remove stale backup from a previous run
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: dbPath, toPath: backupPath)
            migrationLog.info("Pre-migration backup created at \(backupPath)")
        } catch {
            migrationLog.warning("Could not create pre-migration backup: \(error.localizedDescription). Proceeding without backup.")
        }
    }

    static func migrate(_ dbPool: DatabasePool) throws {
        // Back up the database file before any migrations run
        backupDatabaseFile(at: dbPool)

        // Checkpoint WAL to ensure a clean, consistent state before migrating.
        // TRUNCATE mode flushes WAL into the main DB and resets the WAL file.
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }
        migrationLog.info("WAL checkpoint completed before migration")

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

        // Migration 10: Index on fork_from_message_id for getBranches(fromMessage:) performance
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
                do {
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
                            content,
                            content=messages,
                            content_rowid=id
                        )
                        """)
                } catch {
                    migrationLog.error("FTS5 messages_fts creation failed: \(error.localizedDescription). Search will fall back to LIKE.")
                }
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
                do {
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE IF NOT EXISTS conversation_archive_fts USING fts5(
                            compressed_summary, key_entities, key_decisions,
                            content='conversation_archive',
                            content_rowid='rowid'
                        )
                        """)
                } catch {
                    migrationLog.error("FTS5 conversation_archive_fts creation failed: \(error.localizedDescription). Archive search unavailable.")
                }
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
                    do {
                        try db.execute(sql: """
                            CREATE VIRTUAL TABLE IF NOT EXISTS cg_nodes_fts USING fts5(
                                label, content,
                                content='cg_nodes',
                                content_rowid='rowid'
                            )
                            """)
                    } catch {
                        migrationLog.error("FTS5 cg_nodes_fts creation failed: \(error.localizedDescription). Graph search unavailable.")
                    }
                }
            }
        }

        // Migration 16: FTS5 sync triggers for conversation_archive
        // The conversation_archive_fts table was created in v15 but has NO triggers
        // to keep it in sync with conversation_archive. When the daemon writes to
        // conversation_archive, the FTS index becomes stale and search returns
        // outdated results. This adds INSERT/DELETE/UPDATE triggers matching the
        // pattern established in v12 for messages_fts.
        migrator.registerMigration("v16_conversation_archive_fts_triggers") { db in
            // Guard: only create triggers if both tables exist
            let hasFts = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'conversation_archive_fts'
                """) ?? false
            let hasArchive = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master
                WHERE type = 'table' AND name = 'conversation_archive'
                """) ?? false

            guard hasFts && hasArchive else { return }

            // AFTER INSERT: index new rows
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS conversation_archive_fts_ai
                AFTER INSERT ON conversation_archive BEGIN
                    INSERT INTO conversation_archive_fts(rowid, compressed_summary, key_entities, key_decisions)
                    VALUES (new.rowid, new.compressed_summary, new.key_entities, new.key_decisions);
                END
                """)

            // AFTER DELETE: remove deleted rows from index
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS conversation_archive_fts_ad
                AFTER DELETE ON conversation_archive BEGIN
                    INSERT INTO conversation_archive_fts(conversation_archive_fts, rowid, compressed_summary, key_entities, key_decisions)
                    VALUES('delete', old.rowid, old.compressed_summary, old.key_entities, old.key_decisions);
                END
                """)

            // AFTER UPDATE: delete old entry, insert new entry
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS conversation_archive_fts_au
                AFTER UPDATE ON conversation_archive BEGIN
                    INSERT INTO conversation_archive_fts(conversation_archive_fts, rowid, compressed_summary, key_entities, key_decisions)
                    VALUES('delete', old.rowid, old.compressed_summary, old.key_entities, old.key_decisions);
                    INSERT INTO conversation_archive_fts(rowid, compressed_summary, key_entities, key_decisions)
                    VALUES (new.rowid, new.compressed_summary, new.key_entities, new.key_decisions);
                END
                """)

            // Rebuild index from all existing conversation_archive rows
            try db.execute(sql: "INSERT INTO conversation_archive_fts(conversation_archive_fts) VALUES('rebuild')")
        }

        // Migration 17: Denormalize sidebar stats into canvas_trees
        // The sidebar observation query joins messages via canvas_branches on every
        // message insert, causing O(messages) observation churn. Denormalizing
        // message_count, last_message_at, and last_assistant_snippet into canvas_trees
        // lets the sidebar query only canvas_trees. SQLite triggers keep the columns
        // in sync so the observation fires only when canvas_trees rows change.
        migrator.registerMigration("v17_denormalize_sidebar_stats") { db in
            // 1. Add denormalized columns
            try db.execute(sql: "ALTER TABLE canvas_trees ADD COLUMN message_count INTEGER DEFAULT 0")
            try db.execute(sql: "ALTER TABLE canvas_trees ADD COLUMN last_message_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE canvas_trees ADD COLUMN last_assistant_snippet TEXT")

            // 2. Backfill from existing data
            try db.execute(sql: """
                UPDATE canvas_trees SET
                    message_count = COALESCE((
                        SELECT COUNT(m.id) FROM messages m
                        JOIN canvas_branches b ON b.session_id = m.session_id
                        WHERE b.tree_id = canvas_trees.id
                    ), 0),
                    last_message_at = (
                        SELECT MAX(m.timestamp) FROM messages m
                        JOIN canvas_branches b ON b.session_id = m.session_id
                        WHERE b.tree_id = canvas_trees.id
                    ),
                    last_assistant_snippet = (
                        SELECT m.content FROM messages m
                        JOIN canvas_branches b ON b.session_id = m.session_id
                        WHERE b.tree_id = canvas_trees.id AND m.role = 'assistant'
                        ORDER BY m.timestamp DESC LIMIT 1
                    )
                """)

            // 3. Triggers to keep denormalized columns in sync

            // After new message inserted
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS canvas_trees_msg_insert AFTER INSERT ON messages
                WHEN EXISTS (SELECT 1 FROM canvas_branches WHERE session_id = NEW.session_id)
                BEGIN
                    UPDATE canvas_trees SET
                        message_count = message_count + 1,
                        last_message_at = MAX(COALESCE(last_message_at, ''), NEW.timestamp),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = (SELECT tree_id FROM canvas_branches WHERE session_id = NEW.session_id LIMIT 1);

                    UPDATE canvas_trees SET
                        last_assistant_snippet = NEW.content
                    WHERE NEW.role = 'assistant'
                    AND id = (SELECT tree_id FROM canvas_branches WHERE session_id = NEW.session_id LIMIT 1);
                END
                """)

            // After message deleted
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS canvas_trees_msg_delete AFTER DELETE ON messages
                WHEN EXISTS (SELECT 1 FROM canvas_branches WHERE session_id = OLD.session_id)
                BEGIN
                    UPDATE canvas_trees SET
                        message_count = MAX(message_count - 1, 0),
                        updated_at = CURRENT_TIMESTAMP
                    WHERE id = (SELECT tree_id FROM canvas_branches WHERE session_id = OLD.session_id LIMIT 1);
                END
                """)
        }

        // Migration 18: Security approvals table + FK cascade triggers for branch deletes
        //
        // Fix 1: PermissionStore was using UserDefaults — move to database so approvals
        //         persist in the shared SQLite DB and survive container resets.
        // Fix 2: canvas_branch_tags and canvas_api_state had no cascade on branch delete,
        //         leaving orphaned rows. Add cleanup + AFTER DELETE triggers.
        migrator.registerMigration("v18_security_approvals_and_branch_cascade") { db in
            // --- Fix 1: Security approvals table ---
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_security_approvals (
                    pattern TEXT PRIMARY KEY,
                    approved_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            // Migrate existing UserDefaults data into the new table
            let existingApprovals = UserDefaults.standard.stringArray(
                forKey: "com.worldtree.security.approved-patterns"
            ) ?? []
            for pattern in existingApprovals {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO canvas_security_approvals (pattern) VALUES (?)",
                    arguments: [pattern]
                )
            }
            // Clean up UserDefaults after successful migration
            UserDefaults.standard.removeObject(forKey: "com.worldtree.security.approved-patterns")

            // --- Fix 2: FK cascade for branch-dependent tables ---

            // Clean up any existing orphans from past deletes
            try db.execute(sql: """
                DELETE FROM canvas_branch_tags
                WHERE branch_id NOT IN (SELECT id FROM canvas_branches)
                """)
            try db.execute(sql: """
                DELETE FROM canvas_api_state
                WHERE session_id NOT IN (
                    SELECT session_id FROM canvas_branches WHERE session_id IS NOT NULL
                )
                """)

            // Cascade trigger: clean up branch tags when a branch is deleted
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS canvas_branch_cascade_tags
                AFTER DELETE ON canvas_branches
                BEGIN
                    DELETE FROM canvas_branch_tags WHERE branch_id = OLD.id;
                END
                """)

            // Cascade trigger: clean up API state when a branch is deleted
            // canvas_api_state is keyed by session_id, so match on OLD.session_id
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS canvas_branch_cascade_api_state
                AFTER DELETE ON canvas_branches
                BEGIN
                    DELETE FROM canvas_api_state WHERE session_id = OLD.session_id;
                END
                """)
        }

        // Migration 19: Add model column to canvas_token_usage for per-turn model tracking
        migrator.registerMigration("v19_token_usage_model") { db in
            try db.execute(sql: "ALTER TABLE canvas_token_usage ADD COLUMN model TEXT")
        }

        // Migration 20: Per-branch compaction mode
        migrator.registerMigration("v20_compaction_mode") { db in
            try db.execute(sql: "ALTER TABLE canvas_branches ADD COLUMN compaction_mode TEXT DEFAULT 'auto'")
        }

        // Migration 21: Tickets table (TicketMaster absorption)
        migrator.registerMigration("v21_tickets") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_tickets (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    title TEXT NOT NULL,
                    description TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    priority TEXT NOT NULL DEFAULT 'medium',
                    assignee TEXT,
                    sprint TEXT,
                    file_path TEXT,
                    acceptance_criteria TEXT,
                    blockers TEXT,
                    created_at TEXT,
                    updated_at TEXT,
                    last_scanned TEXT DEFAULT (datetime('now'))
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_canvas_tickets_project ON canvas_tickets(project, status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_canvas_tickets_priority ON canvas_tickets(priority)")
        }

        // Migration 22: Pencil assets — .pen file registry + frame→ticket links
        migrator.registerMigration("v22_pencil_assets") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pen_assets (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    file_path TEXT NOT NULL UNIQUE,
                    file_name TEXT NOT NULL,
                    frame_count INTEGER NOT NULL DEFAULT 0,
                    node_count INTEGER NOT NULL DEFAULT 0,
                    raw_json TEXT,
                    last_parsed TEXT,
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now'))
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pen_assets_project ON pen_assets(project)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pen_assets_file ON pen_assets(file_path)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pen_frame_links (
                    id TEXT PRIMARY KEY,
                    asset_id TEXT NOT NULL REFERENCES pen_assets(id) ON DELETE CASCADE,
                    frame_id TEXT NOT NULL,
                    frame_name TEXT,
                    ticket_id TEXT REFERENCES canvas_tickets(id) ON DELETE SET NULL,
                    annotation TEXT,
                    width REAL,
                    height REAL,
                    created_at TEXT DEFAULT (datetime('now')),
                    updated_at TEXT DEFAULT (datetime('now')),
                    UNIQUE(asset_id, frame_id)
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pen_frame_links_asset ON pen_frame_links(asset_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_pen_frame_links_ticket ON pen_frame_links(ticket_id)")
        }

        // Migration 23: Auto-detected decisions review queue (TASK-122)
        migrator.registerMigration("v23_auto_decisions") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS canvas_auto_decisions (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    branch_id TEXT,
                    project TEXT,
                    summary TEXT NOT NULL,
                    rationale TEXT NOT NULL DEFAULT '',
                    context TEXT NOT NULL DEFAULT '',
                    confidence REAL NOT NULL DEFAULT 0.0,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TEXT DEFAULT (datetime('now')),
                    reviewed_at TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_auto_decisions_status ON canvas_auto_decisions(status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_auto_decisions_session ON canvas_auto_decisions(session_id)")
        }

        // Migration 24: Agent session model — sessions, file touches, attention events,
        // event trigger rules, and UI state (TASK-134)
        migrator.registerMigration("v24_agent_sessions") { db in
            // Agent sessions — real-time observability for Command Center
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agent_sessions (
                    id TEXT PRIMARY KEY,
                    agent_name TEXT,
                    project TEXT NOT NULL,
                    working_directory TEXT NOT NULL,
                    source TEXT NOT NULL DEFAULT 'interactive',
                    status TEXT NOT NULL DEFAULT 'starting'
                        CHECK(status IN ('starting','thinking','writing','tool_use','waiting','stuck','idle','completed','failed','interrupted')),
                    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP,
                    last_activity_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    current_task TEXT,
                    current_file TEXT,
                    current_tool TEXT,
                    error_count INTEGER DEFAULT 0,
                    retry_count INTEGER DEFAULT 0,
                    consecutive_errors INTEGER DEFAULT 0,
                    tokens_in INTEGER DEFAULT 0,
                    tokens_out INTEGER DEFAULT 0,
                    context_used INTEGER DEFAULT 0,
                    context_max INTEGER DEFAULT 200000,
                    files_changed TEXT DEFAULT '[]',
                    exit_reason TEXT,
                    dispatch_id TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_sessions_status ON agent_sessions(status)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_sessions_project ON agent_sessions(project)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_sessions_active ON agent_sessions(status) WHERE status NOT IN ('completed', 'failed', 'interrupted')")

            // File touches — conflict detection and activity tracking
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agent_file_touches (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    agent_name TEXT,
                    file_path TEXT NOT NULL,
                    project TEXT NOT NULL,
                    action TEXT NOT NULL DEFAULT 'edit',
                    touched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_file_touches_file ON agent_file_touches(file_path)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_file_touches_session ON agent_file_touches(session_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_file_touches_recent ON agent_file_touches(touched_at)")

            // Attention events — permission prompts, stuck agents, error loops
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agent_attention_events (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    type TEXT NOT NULL CHECK(type IN ('permission_needed','stuck','error_loop','completed','context_low','conflict','review_ready')),
                    severity TEXT NOT NULL DEFAULT 'info' CHECK(severity IN ('critical','warning','info')),
                    message TEXT NOT NULL,
                    metadata TEXT,
                    acknowledged INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    acknowledged_at TIMESTAMP
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_attention_unack ON agent_attention_events(acknowledged, severity)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_attention_session ON agent_attention_events(session_id)")

            // Event trigger rules — user-defined automation
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS event_trigger_rules (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    enabled INTEGER DEFAULT 1,
                    trigger_type TEXT NOT NULL,
                    trigger_config TEXT NOT NULL,
                    action_type TEXT NOT NULL,
                    action_config TEXT NOT NULL,
                    last_triggered_at TIMESTAMP,
                    trigger_count INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)

            // UI state — key-value persistence for view state
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS ui_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                )
                """)
        }

        // Migration 25: Normalize project names and surface orphaned trees
        //
        // Fix 1: "WorldTree" (no space) was used as project name in some older trees —
        //         normalize to "World Tree" so all World Tree chats appear in the same group.
        // Fix 2: Trees with empty/nil project are invisible in the sidebar project list
        //         and the Recent Projects section. Infer a project name from the last
        //         segment of their working_directory so they surface correctly.
        //         Trees whose working_directory is empty or unknown stay in General.
        migrator.registerMigration("v25_normalize_project_names") { db in
            // Fix 1: collapse "WorldTree" into "World Tree"
            try db.execute(sql: """
                UPDATE canvas_trees
                SET project = 'World Tree'
                WHERE project = 'WorldTree'
                """)

            // Fix 2: infer project from working_directory for orphaned trees.
            // SQLite has no REVERSE(), so we do the last-path-component extraction in Swift.
            let orphanRows = try Row.fetchAll(db, sql: """
                SELECT id, working_directory FROM canvas_trees
                WHERE (project IS NULL OR TRIM(project) = '')
                  AND TRIM(COALESCE(working_directory, '')) != ''
                """)
            for row in orphanRows {
                let id: String = row["id"]
                let wd: String = row["working_directory"] ?? ""
                guard !wd.isEmpty else { continue }
                let inferred = URL(fileURLWithPath: wd).lastPathComponent
                guard !inferred.isEmpty, inferred != "/" else { continue }
                try db.execute(
                    sql: "UPDATE canvas_trees SET project = ? WHERE id = ?",
                    arguments: [inferred, id]
                )
            }
        }

        // Fix 3: trees still orphaned (no working_directory) → use tree name as project.
        // Excludes Telegram bridge sessions and trees with generic/empty names.
        migrator.registerMigration("v26_name_fallback_for_no_wd_orphans") { db in
            let remaining = try Row.fetchAll(db, sql: """
                SELECT id, name FROM canvas_trees
                WHERE (project IS NULL OR TRIM(project) = '')
                  AND (working_directory IS NULL OR TRIM(working_directory) = '')
                  AND name NOT LIKE 'Telegram%'
                  AND TRIM(COALESCE(name, '')) != ''
                """)
            for row in remaining {
                let id: String = row["id"]
                let name: String = row["name"] ?? ""
                guard !name.isEmpty else { continue }
                try db.execute(
                    sql: "UPDATE canvas_trees SET project = ? WHERE id = ?",
                    arguments: [name, id]
                )
            }
        }

        try migrator.migrate(dbPool)
    }
}
