# TASK-104: Bridge — WebSocket on ContextServer (WorldTree side)

**Status:** open
**Priority:** high
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 3 (Communication)
**Dependencies:** TASK-102

## What

Add WebSocket upgrade to WorldTree's existing ContextServer (port 4863) at `ws://127.0.0.1:4863/bridge`. Enables bidirectional real-time communication between WorldTree and running sessions.

## Acceptance Criteria

- WebSocket endpoint at `/bridge` on existing NWListener HTTP server
- Accepts `BridgeCommand` messages (instruction, query, cancel) with sessionId + payload
- Emits `BridgeEvent` messages (finding, progress, complete, error, scratchpad_write) with sessionId + project + payload
- Messages are JSON, max 64KB
- Auto-reconnect with exponential backoff (1s, 2s, 4s, max 30s) on client side
- Fire-and-forget semantics — scratchpad is the durable layer, bridge is convenience
- Bridge events stored in `bridge_events` table for replay/history
- Bridge commands stored in `bridge_commands` table for audit

## Key Files

- WorldTree `Sources/Core/ContextServer/` — WebSocket upgrade
- Database: `~/.cortana/world-tree.db` (bridge_events, bridge_commands tables already exist)

## Notes

- No auth needed — localhost only, same security model as existing ContextServer
- WorldTree is the SERVER. Harness daemon is the CLIENT (TASK-105).
