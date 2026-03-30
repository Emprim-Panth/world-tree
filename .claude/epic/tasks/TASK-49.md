### TASK-49: Add missing database indexes
**Epic:** Database
**Why:** Frequently-queried columns lack indexes: `session_state.updated_at`, `canvas_dispatches.completed_at`, `agent_sessions.started_at`.
**Fix:** Add indexes in v39 migration.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
