# TASK-105: Bridge — Harness daemon WebSocket client + hook event forwarding

**Status:** open
**Priority:** high
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 3 (Communication)
**Dependencies:** TASK-101, TASK-104

## What

Build the WebSocket client in the harness daemon that connects to WorldTree's bridge. Forward hook events (scratchpad writes, session state changes) as BridgeEvents.

## Acceptance Criteria

- `cortana-core/src/harness/bridge.ts` — WebSocket client connecting to `ws://127.0.0.1:4863/bridge`
- Auto-reconnect with exponential backoff (1s, 2s, 4s, max 30s)
- Forwards scratchpad_write events from hooks as BridgeEvents
- Forwards session state changes (busy/ready/complete) as BridgeEvents
- Receives BridgeCommands from WorldTree and routes to correct tmux session via send-keys
- Degrades gracefully when WorldTree is not running (queue events, deliver on reconnect — max 100 queued)
- Circuit breaker integration (bridge failures don't crash daemon)

## Key Files

- `cortana-core/src/harness/bridge.ts` — WebSocket client
- `cortana-core/src/harness/index.ts` — daemon integration

## Notes

- Bridge is convenience, not correctness. If it's down, scratchpad still works, sessions still run.
- Evan typing in WorldTree -> BridgeCommand -> harness writes to session stdin via `tmux send-keys`
