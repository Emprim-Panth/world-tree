# TASK-124: Dream Engine — review-queue routing for ambiguous entries

**Status:** open
**Priority:** medium
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 3 — Dream Engine
**Agent:** Dax
**Depends on:** TASK-122
**Blocks:** TASK-133

## What

Scratchpad groups that are ambiguous (wrong namespace, low confidence, or genuinely cross-domain) route to the `review-queue` namespace instead of being silently dropped. They surface in WorldTree's Review Queue panel (TASK-133) for Evan to classify.

## Review-Queue Criteria (ANY of these)

- Confidence score: L (cannot auto-promote)
- Namespace ambiguous — Ollama cannot determine which of 2+ namespaces applies
- Crew member's write access doesn't cover the apparent namespace (e.g., Worker found a cortana-system pattern)
- Content is cross-project by nature (applies to multiple projects simultaneously)

## Action for Review-Queue Entries

```
1. INSERT into knowledge:
   - namespace = 'review-queue'
   - reviewed_at = NULL (pending)
   - body includes: "Suggested namespace: X (confidence: M)"

2. UPDATE scratchpad entries: promoted=1, promoted_at=now()
   (mark as processed — prevents re-queueing on next dream run)

3. Do NOT write mirror file (no confirmed namespace yet)
```

## Acceptance Criteria

- [ ] L-confidence groups → review-queue (not dropped, not promoted to wrong namespace)
- [ ] Ambiguous namespace → review-queue with suggested namespace in body
- [ ] Scratchpad entries marked promoted=1 after queueing (not re-processed)
- [ ] GET /knowledge/review-queue returns these entries (for TASK-133 UI)
- [ ] Review-queue entries have `reviewed_at=NULL` until Evan acts on them (TASK-133)

## Files

- `cortana-core/src/dream/queue.ts`
