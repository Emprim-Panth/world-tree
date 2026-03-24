---
id: TASK-33
title: agent_sessions + agent_screenshots DB tables (v30 migration)
status: done
priority: medium
epic: EPIC-WT-AGENT-WORKSPACE
phase: 3
---

Add v30 migration to MigrationManager.swift. Creates: `agent_sessions(id TEXT PK, project TEXT, task TEXT, started_at TEXT, completed_at TEXT, build_status TEXT, proof_path TEXT)` and `agent_screenshots(id TEXT PK, session_id TEXT, path TEXT, captured_at TEXT, context TEXT)`. Both tables indexed on session_id.
