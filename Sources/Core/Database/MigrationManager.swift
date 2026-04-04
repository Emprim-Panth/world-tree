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

        // v39_cleanup — drop broken triggers from chat era, fix duplicate indexes, add missing indexes.
        migrator.registerMigration("v39_cleanup") { db in
            // Drop triggers that reference dropped canvas_trees/canvas_branches tables
            try db.execute(sql: "DROP TRIGGER IF EXISTS canvas_trees_msg_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS canvas_trees_msg_delete")

            // Drop duplicate FTS triggers (messages_ai/ad/au duplicate messages_fts_ai/ad/au)
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS messages_au")

            // Drop orphaned table referencing dropped canvas_branches
            try db.execute(sql: "DROP TABLE IF EXISTS canvas_branch_tags")

            // Drop duplicate index on knowledge_domains
            try db.execute(sql: "DROP INDEX IF EXISTS idx_kd_domain")

            // Add missing indexes on frequently-queried columns
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_dispatches_completed ON canvas_dispatches(completed_at)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_agent_sessions_started ON agent_sessions(started_at)")

            // Rebuild FTS index to remove duplicates from double-trigger era
            let hasFts = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name='messages_fts'
            """) ?? false
            if hasFts {
                try db.execute(sql: "INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
            }

            migrationLog.info("v39: cleanup complete — broken triggers dropped, indexes fixed, FTS rebuilt")
        }

        // ── v40: Scratchpad — shared agent state (Cortana Harness Phase 1) ──
        migrator.registerMigration("v40_scratchpad") { db in
            // cortana-core creates this table via ensureSchema() on first write.
            // This migration ensures WorldTree can read it even if cortana-core
            // hasn't written yet (CREATE IF NOT EXISTS is safe either way).
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS scratchpad (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    agent TEXT NOT NULL DEFAULT 'cortana',
                    session_id TEXT NOT NULL DEFAULT '',
                    entry_type TEXT NOT NULL CHECK(entry_type IN ('finding', 'decision', 'blocker', 'handoff')),
                    content TEXT NOT NULL,
                    promoted INTEGER NOT NULL DEFAULT 0,
                    promoted_to TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    expires_at TEXT NOT NULL DEFAULT (datetime('now', '+7 days'))
                )
            """)

            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_scratchpad_project ON scratchpad(project, created_at DESC)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_scratchpad_unpromoted ON scratchpad(promoted) WHERE promoted = 0")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_scratchpad_topic ON scratchpad(project, topic)")

            migrationLog.info("v40: scratchpad table ready for Cortana Harness")
        }

        // ── v41: Bridge events — DB-backed harness ↔ WorldTree channel ──
        migrator.registerMigration("v41_bridge_events") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bridge_events (
                    id TEXT PRIMARY KEY,
                    event_type TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bridge_events_created ON bridge_events(created_at DESC)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bridge_commands (
                    id TEXT PRIMARY KEY,
                    command_type TEXT NOT NULL,
                    payload TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    consumed_at TEXT
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_bridge_commands_consumed ON bridge_commands(consumed_at) WHERE consumed_at IS NULL")

            migrationLog.info("v41: bridge_events + bridge_commands tables ready")
        }

        // ── v42: Crew Registry — canonical org chart, seeded from CONSTITUTION.md ──
        // This is the single source of truth for crew hierarchy that all views and agents
        // reference. Pre-seeded with all 24 crew members. Never modified by agents directly —
        // only Evan can amend the roster (see ~/.cortana/CONSTITUTION.md §III–IV).
        migrator.registerMigration("v42_crew_registry") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS crew_registry (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    role TEXT NOT NULL,
                    department TEXT NOT NULL DEFAULT 'coding',
                    tier INTEGER NOT NULL,
                    model TEXT NOT NULL DEFAULT 'sonnet',
                    game_dev_role TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_crew_dept ON crew_registry(department)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_crew_tier ON crew_registry(tier)")

            // Pre-seed all crew. INSERT OR IGNORE — idempotent if re-run.
            let crew: [(id: String, name: String, role: String, dept: String, tier: Int, model: String, gameDevRole: String?)] = [
                // Tier 1 — CTO
                ("cortana",   "Cortana",   "CTO",                              "command",  1, "sonnet", nil),
                // Tier 2 — Department Head (both coding + game-dev)
                ("picard",    "Picard",    "Mission Lead / Epic Architect",     "coding",   2, "sonnet", "Mission Lead"),
                // Tier 3 — Leads (coding + dual game-dev role)
                ("bashir",    "Bashir",    "Debugging Lead",                    "coding",   3, "sonnet", nil),
                ("composer",  "Composer",  "Music / Audio Lead",               "game-dev", 3, "haiku",  "Music / Audio Lead"),
                ("data",      "Data",      "UI/UX Designer",                   "coding",   3, "sonnet", "Art Director"),
                ("dax",       "Dax",       "Integration / Knowledge Lead",     "coding",   3, "haiku",  nil),
                ("garak",     "Garak",     "Adversarial QA",                   "coding",   3, "haiku",  nil),
                ("geordi",    "Geordi",    "Software Architect",               "coding",   3, "sonnet", "Game Architect"),
                ("kim",       "Kim",       "Documentation Lead",               "coding",   3, "haiku",  nil),
                ("q",         "Q",         "Research / Exploration",           "coding",   3, "opus",   nil),
                ("quark",     "Quark",     "Marketing / Revenue",              "coding",   3, "haiku",  "Game Marketing"),
                ("scotty",    "Scotty",    "Build / DevOps",                   "coding",   3, "haiku",  "Game Build Systems"),
                ("seven",     "Seven",     "Competitive Intelligence",         "coding",   3, "sonnet", nil),
                ("spock",     "Spock",     "Strategist / Orchestrator",        "coding",   3, "sonnet", "Game Director / Design Strategist"),
                ("torres",    "Torres",    "Performance Lead",                 "coding",   3, "sonnet", "Game Performance"),
                ("troi",      "Troi",      "UX Research",                      "coding",   3, "haiku",  "Player Experience / UX"),
                ("uhura",     "Uhura",     "Copy / Docs",                      "coding",   3, "haiku",  "Narrative Designer"),
                ("worf",      "Worf",      "QA Lead",                          "coding",   3, "sonnet", "Game QA"),
                // Tier 4 — Workers
                ("nog",       "Nog",       "Data layer, SwiftData, CloudKit",  "coding",   4, "haiku",  "Game data, save systems, analytics"),
                ("obrien",    "O'Brien",   "CI/CD pipeline, release, App Store","coding",  4, "haiku",  nil),
                ("odo",       "Odo",       "Security, audit",                  "coding",   4, "haiku",  nil),
                ("paris",     "Paris",     "Feature implementation",           "coding",   4, "haiku",  "Level Design"),
                ("sato",      "Sato",      "Localization, accessibility",      "coding",   4, "haiku",  "Localization, platform compliance"),
                ("zimmerman", "Zimmerman", "Diagnostics, crash analysis",      "coding",   4, "haiku",  nil),
            ]

            for c in crew {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO crew_registry (id, name, role, department, tier, model, game_dev_role)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.id, c.name, c.role, c.dept, c.tier, c.model, c.gameDevRole])
            }

            migrationLog.info("v42: crew_registry seeded with \(crew.count) crew members")
        }

        // v43_goal_engine — project goals, gap analysis, and project context for Brain Goal Engine.
        // Stores in compass.db alongside Compass project/ticket data.
        migrator.registerMigration("v43_goal_engine") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_goals (
                    id TEXT PRIMARY KEY,
                    project TEXT NOT NULL,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'Active'
                        CHECK(status IN ('Active', 'Achieved', 'Superseded')),
                    file_path TEXT,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_project_goals_project ON project_goals(project, status)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS goal_gaps (
                    id TEXT PRIMARY KEY,
                    goal_id TEXT NOT NULL REFERENCES project_goals(id) ON DELETE CASCADE,
                    description TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'open'
                        CHECK(status IN ('open', 'in_progress', 'closed')),
                    tickets TEXT,
                    notes TEXT
                )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_goal_gaps_goal ON goal_gaps(goal_id, status)")

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_context (
                    project TEXT PRIMARY KEY,
                    fleet TEXT,
                    lead TEXT,
                    active_goal_id TEXT REFERENCES project_goals(id),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                )
            """)

            migrationLog.info("v43: project_goals, goal_gaps, project_context tables created")
        }

        try migrator.migrate(dbPool)
        migrationLog.info("Migration complete")
    }
}
