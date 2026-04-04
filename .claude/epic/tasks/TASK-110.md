# TASK-110: Dream Engine — launchd service + logging

**Status:** open
**Priority:** medium
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 4 (Knowledge Automation)
**Dependencies:** TASK-109

## What

Configure Dream Engine to run automatically via launchd. Nightly schedule + session-count trigger. Structured logging.

## Acceptance Criteria

- `com.cortana.dream.plist` — launchd agent running daily at 02:00 (StartCalendarInterval)
- Also triggered when session count gate is met (harness daemon calls dream on session end if >3 new entries)
- Log output to `~/.cortana/logs/dream.log` with structured entries (timestamp, phase, action, detail)
- `cortana-dream --check` shows gate status without running
- `cortana-dream --force` runs immediately regardless of gates
- `cortana-dream --history` shows last N dream results from dream_log table
- launchd plist installed via `bun run deploy` or manual `launchctl load`
- Dream results visible in WorldTree (dream_log table query from existing infrastructure)

## Key Files

- `com.cortana.dream.plist` — launchd config
- `cortana-core/bin/cortana-dream.ts` — CLI
- `~/.cortana/logs/dream.log` — log output

## Notes

- Keep launchd config simple. The daemon handles complexity, not the scheduler.
- If dream fails, log the error and exit cleanly — launchd will retry next schedule.
