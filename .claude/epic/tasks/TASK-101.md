# TASK-101: Harness Daemon — Bun rewrite with circuit breakers

**Status:** open
**Priority:** critical
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 2 (Session Infrastructure)
**Dependencies:** TASK-098

## What

Build `cortana-core/src/harness/index.ts` — the always-running Bun daemon that replaces the dead Python cortex. Manages session pool, task dispatch, health monitoring, and circuit breakers.

## Acceptance Criteria

- Daemon runs as a long-lived Bun process, managed by launchd (`com.cortana.harness.plist`)
- Per-service circuit breaker: 3 failures -> open, 5min recovery window, exponential backoff
- Gateway connection is optional — daemon degrades gracefully without it
- Health file written every 30s to `~/.cortana/harness-health.json` (pid, uptime, pool status, circuit states)
- launchd KeepAlive on crash with auto-restart
- CLI entry point: `cortana-core/bin/cortana-harness.ts` (start, stop, status)
- Bash wrapper at `~/.cortana/bin/cortana-harness`
- Clean shutdown on SIGTERM/SIGINT (drain pool, close connections)
- Startup logs to `~/.cortana/logs/harness.log`

## Key Files

- `cortana-core/src/harness/index.ts` — daemon core
- `cortana-core/src/harness/circuit-breaker.ts` — circuit breaker implementation
- `cortana-core/bin/cortana-harness.ts` — CLI
- `~/.cortana/bin/cortana-harness` — bash wrapper
- `com.cortana.harness.plist` — launchd config

## Notes

- Model tier enforcement per Constitution II: CTO=sonnet (opus on escalation), Heads/Leads=sonnet, Workers=haiku
- `launchClaude()` method enforces model per role
- Session Pool (TASK-102) and Bridge client (TASK-105) are subsystems of this daemon
