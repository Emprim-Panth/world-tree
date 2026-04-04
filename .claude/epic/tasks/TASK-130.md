# TASK-130: Migration — crew MEMORY.md files → scratchpad + knowledge table

**Status:** open
**Priority:** medium
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 4 — Knowledge Migration
**Agent:** Dax
**Depends on:** TASK-114, TASK-128
**Blocks:** TASK-131

## What

Migrate crew MEMORY.md files. Recent entries go to scratchpad (working memory). Older entries that look like patterns or decisions go directly to the knowledge table.

## Source Files

`~/.cortana/starfleet/crew/{name}/MEMORY.md` and `~/.cortana/starfleet/crew/{name}/memory/MEMORY.md` (some crew have both)

## Routing Logic

For each entry in a crew MEMORY.md:
- Parse `created_at` if present (look for date stamps in content)
- If within last 7 days → INSERT into scratchpad (crew_member, namespace inferred, promoted=0)
- If older than 7 days AND content looks like a pattern/correction → INSERT into knowledge (promoted=1 since it came from settled memory)
- If older and just a log entry → skip (historical noise, not worth migrating)

## Acceptance Criteria

- [ ] Recent entries (< 7 days) → scratchpad with correct crew_member
- [ ] Older high-signal entries → knowledge table
- [ ] MEMORY.md entries that are just timestamped logs (no Rule/Why) → skipped
- [ ] No duplicate insertions vs entries already migrated by TASK-128
- [ ] Output: `{name}: N scratchpad entries, M knowledge entries, K skipped.`

## Files

- `cortana-core/bin/migrate-memory.ts` — new script
