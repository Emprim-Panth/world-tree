# TASK-108: WorldTree UI — Direct Channel

**Status:** open
**Priority:** medium
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 3 (Communication)
**Dependencies:** TASK-104, TASK-106

## What

Send a message to a running Claude Code session directly from WorldTree. Select a session from the pool, type a message, it arrives in the session's stdin.

## Acceptance Criteria

- Text input field in Session Pool View (per-session or modal)
- Send button dispatches BridgeCommand (type: instruction) with sessionId + message payload
- Harness receives command, writes to session via `tmux send-keys`
- Visual confirmation that message was sent (not that it was processed — fire and forget)
- Message history shown inline (from bridge_commands table)
- Keyboard shortcut: Cmd+Enter to send

## Key Files

- WorldTree `Sources/Features/Sessions/` — Direct Channel UI
- Integrates with Session Pool View (TASK-106)
- Uses Bridge (TASK-104) for transport

## Notes

- This replaces the need to manually `tmux attach` to talk to a session.
- Messages are instructions, not conversation — agents act on them as directives.
