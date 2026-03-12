# TASK-138: cortana-core Hook — Write agent_sessions Data

**Priority**: critical
**Status**: Todo
**Category**: backend
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: scotty
**Complexity**: L
**Dependencies**: TASK-134

## Description

Add agent_sessions writes to cortana-core's hook system. This is the data pipeline that feeds everything World Tree displays. Without this, the status board has no data.

## Files to Modify

- **Modify**: `/Users/evanprimeau/Development/cortana-core/bin/cortana-hooks.ts` — Add agent_sessions INSERT/UPDATE on hook events
- **Modify**: `/Users/evanprimeau/Development/cortana-core/src/state/index.ts` — Extend session state tracking to write agent_sessions

## Hook Event Mapping

### SessionStart
```sql
INSERT INTO agent_sessions (id, project, working_directory, source, status, current_task, started_at, last_activity_at)
VALUES (?, ?, ?, ?, 'starting', ?, datetime('now'), datetime('now'))
```
- `id` = session ID from hook context
- `source` = 'interactive' for conversation sessions, 'dispatch' for cortana-dispatch
- `current_task` = initial goal if available from session_state

### UserPromptSubmit
```sql
UPDATE agent_sessions SET
    status = 'thinking',
    last_activity_at = datetime('now'),
    current_task = COALESCE(?, current_task)
WHERE id = ?
```

### PostToolUse
```sql
UPDATE agent_sessions SET
    status = 'tool_use',
    current_tool = ?,
    current_file = ?,
    last_activity_at = datetime('now'),
    error_count = error_count + CASE WHEN ? THEN 1 ELSE 0 END,
    consecutive_errors = CASE WHEN ? THEN consecutive_errors + 1 ELSE 0 END
WHERE id = ?
```
Also INSERT into `agent_file_touches` when tool is file_edit, write, or bash with file args:
```sql
INSERT INTO agent_file_touches (session_id, agent_name, file_path, project, action)
VALUES (?, ?, ?, ?, ?)
```

### Stop / SessionEnd
```sql
UPDATE agent_sessions SET
    status = CASE WHEN ? THEN 'failed' ELSE 'completed' END,
    completed_at = datetime('now'),
    last_activity_at = datetime('now'),
    exit_reason = ?,
    files_changed = ?,
    tokens_in = ?,
    tokens_out = ?
WHERE id = ?
```
- `files_changed` from session_state.files_touched
- Token totals from accumulated session tracking

### Writing detection (response streaming)
When cortana-core detects active streaming (between PostToolUse events):
```sql
UPDATE agent_sessions SET status = 'writing', last_activity_at = datetime('now') WHERE id = ?
```

## Agent Name Resolution

- If dispatched via cortana-dispatch with a crew agent, use that agent name
- If dispatched via heartbeat, parse from dispatch_queue.crew_agent
- Interactive sessions: agent_name = NULL (displayed as "interactive" in UI)

## Attention Event Generation

Create `agent_attention_events` rows for:
- **error_loop**: When `consecutive_errors >= 3` → type='error_loop', severity='warning'
- **context_low**: When estimated context_used > 0.85 * context_max → type='context_low', severity='warning'
- **completed**: When session completes → type='completed', severity='info' (only for dispatch sessions)

## Acceptance Criteria

- [ ] SessionStart creates agent_sessions row
- [ ] PostToolUse updates status, current_tool, current_file, error counts
- [ ] PostToolUse inserts file touches for file-editing tools
- [ ] Stop/SessionEnd marks session as completed/failed with final stats
- [ ] Agent name resolved from dispatch context when available
- [ ] Attention events created for error loops and context exhaustion
- [ ] Existing hook functionality not broken (all existing tests pass)
- [ ] Defensive: table existence check before every write (CREATE TABLE IF NOT EXISTS at startup)
