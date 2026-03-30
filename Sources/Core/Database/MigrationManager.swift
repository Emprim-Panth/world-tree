import Foundation
import GRDB
import os.log

private let migrationLog = Logger(subsystem: "com.forgeandcode.WorldTree", category: "Migration")

/// Manages canvas-specific schema migrations.
/// Only creates/manages canvas_tickets and canvas_dispatches — never touches cortana-core tables.
///
/// Migration history note: v1–v28 existed in the chat-era app and are already recorded in
/// grdb_migrations on existing databases. They will not re-run. This rewrite only registers
/// the two tables World Tree still owns, plus a cleanup pass to drop orphaned chat tables.
enum MigrationManager {

    private static func backupDatabaseFile(at pool: DatabasePool) {
        do {
            let dbPath = pool.path
            let backupPath = dbPath + ".pre-migration-backup"
            let fm = FileManager.default
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: dbPath, toPath: backupPath)
            migrationLog.info("Pre-migration backup created at \(backupPath)")
        } catch {
            migrationLog.warning("Could not create pre-migration backup: \(error.localizedDescription). Proceeding without backup.")
        }
    }

    static func migrate(_ dbPool: DatabasePool) throws {
        backupDatabaseFile(at: dbPool)

        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
        }
        migrationLog.info("WAL checkpoint completed before migration")

        var migrator = DatabaseMigrator().disablingDeferredForeignKeyChecks()

        // v13_dispatches — canvas_dispatches table (retained from chat era, still used)
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

        // v21_tickets — canvas_tickets table (retained, still used)
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

        // v29_drop_chat_tables — drops all canvas tables that belonged to the chat era.
        // Safe on fresh installs (IF EXISTS). On existing installs this reclaims disk space.
        // Does NOT touch cortana-core owned tables (sessions, messages, summaries, etc.)
        migrator.registerMigration("v29_drop_chat_tables") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS canvas_trees")
            try db.execute(sql: "DROP TABLE IF EXISTS canvas_branches")
            try db.execute(sql: "DROP TABLE IF EXISTS canvas_jobs")
            try db.execute(sql: "DROP TABLE IF EXISTS pen_assets")
            try db.execute(sql: "DROP TABLE IF EXISTS pen_frame_links")
            migrationLog.info("Dropped orphaned chat-era canvas tables")
        }

        // v30_agent_workspace — agent session proof storage for World Tree Status Board.
        // agent_sessions: lightweight proof record per dispatch session (proof_path, build_status).
        //   Note: cortana-core's agent-sessions.ts owns the richer live-tracking schema;
        //   this CREATE IF NOT EXISTS is a no-op on existing installs and creates the table
        //   on fresh installs for forward compat.
        // agent_screenshots: screenshot paths captured during dispatch sessions.
        migrator.registerMigration("v30_agent_workspace") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agent_sessions (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    task TEXT,
                    started_at TEXT NOT NULL,
                    completed_at TEXT,
                    build_status TEXT,
                    proof_path TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_sessions_project ON agent_sessions(project)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS agent_screenshots (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    captured_at TEXT NOT NULL,
                    context TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_screenshots_session ON agent_screenshots(session_id)")

            migrationLog.info("v30: agent_sessions + agent_screenshots tables ready")
        }

        // v31_agent_columns — cortana-core's agent-sessions.ts created agent_sessions first
        // with a richer schema (current_task, exit_reason instead of task, build_status).
        // If this install's agent_sessions came from TS, it's missing task, build_status,
        // and proof_path. Note: SQLite has no "ADD COLUMN IF NOT EXISTS" — check via
        // pragma_table_info before each ALTER TABLE to avoid "duplicate column" errors.
        migrator.registerMigration("v31_agent_columns") { db in
            let existingColumns = try String.fetchAll(
                db,
                sql: "SELECT name FROM pragma_table_info('agent_sessions')"
            )
            if !existingColumns.contains("task") {
                try db.execute(sql: "ALTER TABLE agent_sessions ADD COLUMN task TEXT")
            }
            if !existingColumns.contains("build_status") {
                try db.execute(sql: "ALTER TABLE agent_sessions ADD COLUMN build_status TEXT")
            }
            if !existingColumns.contains("proof_path") {
                try db.execute(sql: "ALTER TABLE agent_sessions ADD COLUMN proof_path TEXT")
            }
            migrationLog.info("v31: agent_sessions missing columns patched")
        }

        // v35_inference_log — tracks routing decisions for the Intelligence Dashboard.
        migrator.registerMigration("v35_inference_log") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS inference_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_type TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    input_tokens INTEGER,
                    output_tokens INTEGER,
                    latency_ms INTEGER,
                    confidence TEXT,
                    escalated INTEGER DEFAULT 0,
                    escalation_reason TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_inference_log_date ON inference_log(created_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_inference_log_provider ON inference_log(provider)")
            migrationLog.info("v35: inference_log table ready")
        }

        // v36_cortana_alerts — drift/health alerts surfaced in WorldTree Briefing panel.
        migrator.registerMigration("v36_cortana_alerts") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cortana_alerts (
                    id TEXT PRIMARY KEY,
                    type TEXT NOT NULL,
                    project TEXT,
                    message TEXT NOT NULL,
                    severity TEXT NOT NULL DEFAULT 'info'
                        CHECK(severity IN ('info','warning','critical')),
                    source TEXT NOT NULL DEFAULT 'manual',
                    resolved INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT (datetime('now')),
                    resolved_at TEXT
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_alerts_resolved ON cortana_alerts(resolved, created_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_alerts_project ON cortana_alerts(project)")
            migrationLog.info("v36: cortana_alerts table ready")
        }

        // v37_starfleet_activity — agent lifecycle events for Starfleet Command panel.
        migrator.registerMigration("v37_starfleet_activity") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS starfleet_activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_name TEXT NOT NULL,
                    event_type TEXT NOT NULL
                        CHECK(event_type IN ('start','stop','error','dispatch','complete','heartbeat')),
                    project TEXT,
                    detail TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_starfleet_agent ON starfleet_activity(agent_name, created_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_starfleet_date ON starfleet_activity(created_at)")
            migrationLog.info("v37: starfleet_activity table ready")
        }

        // v38_hook_events — raw hook event log for pattern analysis and knowledge promotion.
        migrator.registerMigration("v38_hook_events") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS hook_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    hook_type TEXT NOT NULL,
                    session_id TEXT,
                    project TEXT,
                    payload TEXT,
                    created_at TEXT DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_hook_type ON hook_events(hook_type, created_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_hook_session ON hook_events(session_id)")
            migrationLog.info("v38: hook_events table ready")
        }

        try migrator.migrate(dbPool)
        migrationLog.info("Migration complete")
    }
}
