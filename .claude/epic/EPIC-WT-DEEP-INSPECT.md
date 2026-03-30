# EPIC-WT-DEEP-INSPECT: Multi-Wave Deep Inspection Findings

**Status:** OPEN
**Date:** 2026-03-29
**Source:** 5 parallel deep inspections (database, architecture, agent ecosystem, ContextServer, intelligence layer)

---

## Summary

Five concurrent deep audits across every layer of the World Tree + Cortana ecosystem. 80+ findings across database integrity, code architecture, agent gaps, API design, and brain intelligence. Organized by priority for systematic resolution.

---

## CRITICAL (Fix Immediately)

### TASK-41: Drop broken triggers and duplicate FTS indexes
**Epic:** Database
**Why:** Every message INSERT fires triggers referencing dropped `canvas_trees`/`canvas_branches` tables + duplicate FTS triggers cause double-indexing of all 19,921 messages. Silent overhead on every write.
**Fix:** Add v39 migration: drop `canvas_trees_msg_insert`, `canvas_trees_msg_delete` triggers, drop duplicate `messages_ai`/`messages_ad`/`messages_au` triggers, rebuild FTS index, drop `canvas_branch_tags` table, drop duplicate `idx_kd_domain` index.

### TASK-42: Migrate all stores from ObservableObject to @Observable
**Epic:** Architecture
**Why:** Mixed `@Observable` and `ObservableObject` is the #1 performance issue. Every `@ObservedObject` store triggers full view rebuilds on ANY `@Published` change. CommandCenterView alone re-renders on 10+ properties it doesn't read.
**Stores to migrate:** CompassStore, HeartbeatStore, DispatchActivityStore, BrainFileStore, CentralBrainStore, BriefingStore, SystemHealthStore, StarfleetStore, QualityRouter, BrainIndexer, TicketStore (11 stores).

### TASK-43: Fix ContextServer body truncation at 64KB
**Epic:** ContextServer
**Why:** Single-read of 65536 bytes means any POST body > 64KB silently fails. No timeout on connections (slowloris risk). No connection limit.
**Fix:** Accumulate reads until Content-Length satisfied or isComplete. Add 30s connection deadline. Add 50-connection limit.

### TASK-44: Fix who-i-am.md BookBuddy contradiction
**Epic:** Brain
**Why:** Line 39 says "Prime revenue target: Ship BookBuddy v1" but BookBuddy is archived. This is the most-read brain file — every session gets the wrong priority signal.
**Fix:** Update line 39 to reference BIM Manager. Update projects/WorldTree.md to reflect Build 14. Update portfolio.md with all active projects.

### TASK-45: Deploy cortana-dream.sh as LaunchAgent
**Epic:** Brain
**Why:** The dream agent is the ONLY mechanism that catches brain contradictions automatically. It was written, tested, and never deployed. The contradictions found in this audit would have been caught by dream.
**Fix:** Create com.cortana.dream.plist, load it. Set 5-day interval.

---

## HIGH (Fix This Week)

### TASK-46: Delete dead code (NotificationManager, WakeLock, SessionStateStore)
**Epic:** Architecture
**Why:** 301 lines of code that's defined but never called. Violates anti-duplication rule. NotificationManager (71 LOC), WakeLock (71 LOC), SessionStateStore (159 LOC).
**Fix:** Delete the 3 files, regenerate xcodeproj.

### TASK-47: Fix BrainFileStore file descriptor leak
**Epic:** Architecture
**Why:** `BrainFileStore.watch()` calls `open()` TWICE when fd is valid — first in the guard condition, second for the value. First fd leaks.
**Fix:** Change to `let fd = open(url.path, O_EVTONLY); guard fd != -1 else { return }`.

### TASK-48: Add WAL checkpoints for compass.db and brain-index.db
**Epic:** Database
**Why:** brain-index.db WAL is 3.2MB (4x the DB). compass.db WAL is 300KB. Neither has a checkpoint timer. WAL will grow unbounded.
**Fix:** Add checkpoint timer to CompassStore and BrainIndexer (30-second interval like DatabaseManager).

### TASK-49: Add missing database indexes
**Epic:** Database
**Why:** Frequently-queried columns lack indexes: `session_state.updated_at`, `canvas_dispatches.completed_at`, `agent_sessions.started_at`.
**Fix:** Add indexes in v39 migration.

### TASK-50: Deduplicate HeartbeatStore sync/async refresh
**Epic:** Architecture
**Why:** 280 lines of nearly identical code (sync `refresh()` and `fetchAllAsync()`). Maintenance burden — bugs fixed in one aren't fixed in the other.
**Fix:** Delete sync `refresh()`, keep only `refreshAsync()`. Update callers.

### TASK-51: Connect briefing generation to briefing-inject
**Epic:** Brain
**Why:** morning-briefing.sh sends briefings via iMessage but NEVER writes to `~/.cortana/briefings/`. briefing-inject.sh looks for files there but finds nothing. The two halves of the system don't talk to each other.
**Fix:** Add write to `~/.cortana/briefings/YYYY-MM-DD.md` in morning-briefing.sh. Re-register morning briefing LaunchAgent on Mac Studio.

### TASK-52: Add Compass/Ticket API endpoints to ContextServer
**Epic:** ContextServer
**Why:** Core World Tree data (compass state, tickets) has no HTTP API. CLI tools and remote agents must go directly to SQLite files. Blocks mobile/remote access.
**Fix:** Add GET /compass/{project}, GET /compass/overview, GET /tickets/{project}, POST /alerts, PATCH /alerts/{id}.

### TASK-53: Security hardening — move tokens to Keychain
**Epic:** Agent Ecosystem
**Why:** nerve.toml contains bearer tokens in plaintext. No secret scanning in commits. No cert expiry monitoring.
**Fix:** Move nerve tokens to Keychain. Add pre-commit secret scanning hook. Add cert expiry alert (30-day warning).

### TASK-54: Fix knowledge-promote.sh expire function
**Epic:** Brain
**Why:** The `expire` command logs expired candidates but never actually deletes them. The deletion sed command is missing.
**Fix:** Add sed deletion after the logging loop.

---

## MEDIUM (Fix This Month)

### TASK-55: Add data retention policies
**Epic:** Database
**Why:** signal_log at 56K rows, canvas_dispatches at 1.8K, ticket_cache at 2.9K — all growing without bounds. No cleanup, no VACUUM.
**Fix:** Add retention sweep: keep 30 days of signal_log, 90 days of dispatches, 14 days of inference_log. Schedule via dream agent or cron.

### TASK-56: Create missing project brain files
**Epic:** Brain
**Why:** DocForge, Archon-CAD, cortana-core, cortana-vision have no brain files despite being active projects.
**Fix:** Create minimal project files from DIRECTOR-BRIEF data.

### TASK-57: Move TicketStore.scanAll() off main thread
**Epic:** Architecture
**Why:** Iterates every project directory, reads every TASK-*.md, parses with regex, and upserts to DB — all on MainActor. Blocks UI for large project sets.
**Fix:** Move file scanning to Task.detached, update published state on completion.

### TASK-58: Create shared DateParsing utility
**Epic:** Architecture
**Why:** ISO8601 date parsing with 3+ fallback strategies duplicated in 5+ locations (CompassState, AgentLabViewModel x2, HeartbeatStore, StarfleetStore).
**Fix:** Extract to `DateParsing.parseFlexible(_ str: String) -> Date?`.

### TASK-59: Unify agent naming (kill Pantheon references)
**Epic:** Agent Ecosystem
**Why:** Three naming systems coexist: Pantheon (config.toml, cortana-vision AGENTS.md), Starfleet (config.yaml), and cortana-core routing (mixed). Naming collision causes confusion.
**Fix:** Remove Pantheon references. Standardize on Starfleet names in all config files.

### TASK-60: Activate stalled LaunchAgents
**Epic:** Agent Ecosystem
**Why:** Watchtower, Reconciler, and Reflex have plists but aren't running. Morning briefing not registered on Mac Studio. Dream never deployed.
**Fix:** Audit each, activate or remove. Deploy dream and morning briefing.

### TASK-61: Replace manual JSON construction in ContextServer
**Epic:** ContextServer
**Why:** 10+ locations build JSON via string interpolation. Fragile, hard to maintain, risk of malformed output.
**Fix:** Define Codable response structs, use JSONEncoder for all responses.

### TASK-62: BrainIndexer search performance — cache embeddings
**Epic:** Database
**Why:** Loads ALL embeddings into memory (full table scan) on every search query. Currently 89 chunks, will degrade at 1000+.
**Fix:** Cache embeddings in memory after indexAll(). Invalidate on re-index. Consider sqlite-vss for vector search.

---

## LOW (Backlog)

### TASK-63: Make Ticket.status a proper enum
**Why:** Raw strings ("pending", "in_progress", etc.) used throughout. Palette.forStatus() already maps them.

### TASK-64: Extract FileWatcher utility
**Why:** DispatchSource file-watching pattern repeated in 4 files.

### TASK-65: Remove AppState.gatewayReachable, contextServerReachable, lastHeartbeatAt
**Why:** Written but never read by any view. Dead state.

### TASK-66: Add input_tokens/output_tokens to inference/recent response
**Why:** Data is queried from DB but dropped in JSON construction.

### TASK-67: ContextServer — return 405 instead of 404 for wrong methods
**Why:** Incorrect HTTP semantics (minor).

### TASK-68: Reduce SessionStart injection volume
**Why:** 17+ § signals injected every session. Signals from empty directories (morning_brief, drift_alerts) waste tokens. Measure which signals influence behavior.

---

## New Agent Proposals

### Chief (Security Operations) — CRITICAL
Replace empty Garak shell. Owns: dependency scanning, secret detection, cert expiry monitoring, token rotation, permission auditing.

### Keyes (Revenue & Analytics) — HIGH
Named for Captain Keyes. Owns: revenue tracking, time-per-project analytics, velocity metrics, cost monitoring, weekly business reports. The Prime Directive has no measurement system.

### Roland (Log Intelligence) — MEDIUM
Named for UNSC Infinity AI. Owns: log aggregation from ~/.cortana/logs/ (110+ files), anomaly detection, error pattern recognition.

### Halsey (Test Automation) — MEDIUM
Named for Dr. Halsey. Owns: automated regression test generation, visual regression, test coverage tracking.

---

## Metrics

| Category | Findings | Critical | High | Medium | Low |
|----------|----------|----------|------|--------|-----|
| Database | 25 | 3 | 4 | 3 | 5 |
| Architecture | 30 | 1 | 6 | 3 | 4 |
| Agent Ecosystem | 15 | 1 | 4 | 4 | 2 |
| ContextServer | 15 | 1 | 3 | 2 | 3 |
| Brain/Intelligence | 15 | 2 | 4 | 3 | 2 |
| **Total** | **80+** | **8** | **21** | **15** | **16** |
