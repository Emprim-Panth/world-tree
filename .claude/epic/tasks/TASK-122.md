# TASK-122: Dream Engine — crew-aware scratchpad pass

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 3 — Dream Engine
**Agent:** Dax (Knowledge Lead)
**Depends on:** TASK-114, TASK-121
**Blocks:** TASK-123, TASK-124, TASK-125, TASK-126

## What

Extend the Dream Engine (from EPIC-CORTANA-HARNESS) to process scratchpad entries per-crew-member and per-namespace. The current dream engine (if implemented) treats all scratchpad entries as a single pool. This task makes it crew-aware.

## Dream Cycle Per Crew Member

For each active crew member with unreviewed scratchpad entries (promoted=0, created_at > cutoff):

```
1. ORIENT
   - Load crew member's registry entry (tier, namespaces_write)
   - Load their recent scratchpad entries grouped by namespace
   - Load their existing promoted knowledge for context (avoid duplicates)

2. GATHER
   - Group scratchpad entries by topic similarity (local Ollama: qwen2.5:72b)
   - Score each group: confidence (H/M/L), novelty vs existing knowledge, ambiguity

3. Route to TASK-123 (promote), TASK-124 (review-queue), or TASK-126 (prune)
```

## Trigger Conditions

- **Nightly**: 02:00 via LaunchAgent (TASK-138)
- **Session end**: if crew member wrote > 3 scratchpad entries this session (hook)

## Acceptance Criteria

- [ ] Dream engine iterates all crew members with pending scratchpad entries
- [ ] Per crew member: groups entries by topic using Ollama embedding similarity
- [ ] Each group scored for confidence and novelty
- [ ] Groups handed to promote/queue/prune based on score
- [ ] Dream run logged to `~/.cortana/logs/cortana-dream.log` with: crew_member, entries_processed, promoted, queued, pruned
- [ ] Idempotent — re-running dream on same entries does not double-promote

## Files

- `cortana-core/src/dream/` — new directory
- `cortana-core/src/dream/crew-dream.ts` — main crew-aware pass
- `cortana-core/src/dream/grouping.ts` — topic grouping via Ollama embeddings
