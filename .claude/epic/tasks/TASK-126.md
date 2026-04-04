# TASK-126: Dream Engine — 7-day scratchpad prune

**Status:** open
**Priority:** low
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 3 — Dream Engine
**Agent:** Scotty
**Depends on:** TASK-122
**Blocks:** TASK-138

## What

The prune step deletes stale scratchpad entries that were not promoted. Keeps the scratchpad lean and prevents old noise from appearing in future session context injections.

## Prune Rules

Delete rows from `scratchpad` where:
- `promoted = 0` (not yet promoted — was never worth promoting)
- `created_at < datetime('now', '-7 days')`
- crew_member IS NOT NULL (don't prune legacy pre-enforcement entries aggressively — let them age naturally at 30 days)

## What Is NOT Pruned

- `promoted = 1` entries — they stay as historical record (not re-processed)
- Entries < 7 days old — still in working memory window
- Entries with `crew_member IS NULL` and age < 30 days — legacy, handled separately

## Acceptance Criteria

- [ ] Prune runs as last step of each dream cycle
- [ ] Only deletes: unpromoted + older than 7 days + has crew_member
- [ ] Returns count of pruned rows for dream log
- [ ] Test: insert 10 rows with created_at = 8 days ago, promoted=0 → all deleted after prune
- [ ] Test: insert 5 rows with created_at = 8 days ago, promoted=1 → none deleted

## Files

- `cortana-core/src/dream/prune.ts`
