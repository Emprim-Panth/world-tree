# TASK-134: Agent Session Model + Database Migration

**Priority**: critical
**Status**: Done
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: geordi
**Complexity**: M
**Dependencies**: none

## Description

Create the `AgentSession` GRDB model and database migration for the `agent_sessions`, `agent_file_touches`, and `agent_attention_events` tables. This is the foundation every other task depends on.

## Files to Create/Modify

- **Create**: `Sources/Core/Models/AgentSession.swift` — GRDB `Codable`, `FetchableRecord`, `PersistableRecord` model following `WorldTreeDispatch` pattern exactly
- **Create**: `Sources/Core/Models/AttentionEvent.swift` — GRDB model for attention events
- **Modify**: `Sources/Core/Database/MigrationManager.swift` — Add migration `v_agent_orchestration_tables` creating all 5 new tables (agent_sessions, agent_file_touches, agent_attention_events, event_trigger_rules, ui_state)

## Implementation Notes

- AgentSession.status should be a `DatabaseValueConvertible` enum matching the CHECK constraint
- CodingKeys must map snake_case columns to camelCase properties (see WorldTreeDispatch.CodingKeys pattern)
- files_changed stored as JSON string, decoded via helper computed property returning `[String]`
- context_used and context_max default to 0 and 200000 respectively
- Migration must use `CREATE TABLE IF NOT EXISTS` — shared DB, other processes may create tables
- Add `IF NOT EXISTS` to all CREATE INDEX statements
- Pre-migration WAL checkpoint uses PASSIVE (not TRUNCATE) per architecture constraint

## Acceptance Criteria

- [ ] `AgentSession` struct compiles with all fields from schema
- [ ] `AttentionEvent` struct compiles with all fields from schema
- [ ] Migration runs cleanly on fresh DB and on existing DB with prior migrations
- [ ] All 5 tables created with correct schemas and indexes
- [ ] Unit test: insert + fetch AgentSession round-trips correctly
- [ ] Unit test: migration is idempotent (running twice doesn't crash)
