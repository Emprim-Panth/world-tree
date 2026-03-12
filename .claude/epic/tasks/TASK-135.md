# TASK-135: AgentStatusStore — Reactive Observation Layer

**Priority**: critical
**Status**: Done
**Category**: architecture
**Epic**: Agent Orchestration Dashboard
**Sprint**: 1
**Agent**: geordi
**Complexity**: L
**Dependencies**: TASK-134

## Description

Create `AgentStatusStore` — the reactive data layer that feeds the Agent Status Board. Uses GRDB `ValueObservation` to push updates to SwiftUI whenever agent_sessions or session_state changes. Includes a watchdog that marks stale sessions as 'stuck'.

## Files to Create/Modify

- **Create**: `Sources/Core/Database/AgentStatusStore.swift`

## Implementation Pattern

Follow `HeartbeatStore` pattern exactly:
- `@MainActor final class AgentStatusStore: ObservableObject`
- `static let shared = AgentStatusStore()`
- Published properties: `activeSessions: [AgentSession]`, `recentCompleted: [AgentSession]`, `stuckSessions: [AgentSession]`
- `refreshAsync()` method that reads on GRDB's reader queue, assigns on MainActor
- `startObserving()` that sets up `ValueObservation` on `agent_sessions` table
- `stopObserving()` for cleanup

### Data Enrichment

The store should JOIN agent_sessions with session_state to get:
- `goal` from session_state where session_id matches
- `phase` from session_state
- `errors_encountered` count from session_state
- `files_touched` from session_state

### Watchdog Logic

Timer every 30 seconds (match DispatchSupervisor pattern):
- Query active sessions where `last_activity_at < datetime('now', '-5 minutes')`
- For each, check if the tmux/process is still alive (cross-reference DaemonService.tmuxSessions)
- If process dead: update status to 'failed', set exit_reason = 'process_died'
- If process alive but no activity: update status to 'stuck'
- Create agent_attention_events for stuck sessions (type='stuck', severity='warning')

### Context Usage Estimation

Compute `context_used` from canvas_token_usage:
- Sum all input_tokens for the session_id
- Rough estimate: context_used = total_input_tokens (each turn re-sends context)
- Set context_max based on model (200K for sonnet/opus, 200K for haiku)

## Acceptance Criteria

- [ ] ValueObservation fires on agent_sessions INSERT/UPDATE
- [ ] activeSessions only includes non-terminal statuses
- [ ] recentCompleted shows last 20 completed/failed sessions
- [ ] Watchdog marks stale sessions as stuck after 5 minutes of inactivity
- [ ] Context usage calculated from token history
- [ ] All DB reads happen off MainActor (asyncRead pattern)
- [ ] No force unwraps anywhere
