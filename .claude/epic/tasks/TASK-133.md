# TASK-133: WorldTree — Review Queue panel

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 5 — WorldTree UI
**Agent:** Data (Designer) + Torres (Frontend)
**Depends on:** TASK-119, TASK-124
**Blocks:** TASK-141

## What

A new panel in WorldTree that shows all knowledge entries with namespace='review-queue'. Evan reviews them, assigns each to the correct namespace, and approves or deletes. This is the human-in-the-loop for ambiguous knowledge routing.

## UI Layout

```
┌─ Review Queue ──────────────────────────────────────────────┐
│ 12 entries pending                                    [Clear all read] │
├─────────────────────────────────────────────────────────────┤
│ ◉ "Ribbon height: use available_height()"                    │
│   Crew: worf  |  Suggested: archon-cad  |  Type: PATTERN    │
│   [archon-cad ▾]  [Approve]  [Delete]                       │
├─────────────────────────────────────────────────────────────┤
│ ○ "Game balance: enemy spawn rates in wave 3..."             │
│   Crew: paris  |  Suggested: game-dev  |  Type: OBSERVATION │
│   [game-dev ▾]  [Approve]  [Delete]                         │
└─────────────────────────────────────────────────────────────┘
```

## Actions

- **Namespace picker**: dropdown of 11 namespaces, pre-filled with Ollama's suggestion
- **Approve**: updates namespace from 'review-queue' to selected namespace, sets reviewed_at=now()
- **Delete**: removes the knowledge row entirely

## Data Source

`GET /knowledge/review-queue` → all rows where namespace='review-queue' and reviewed_at IS NULL

## Acceptance Criteria

- [ ] Panel accessible from WorldTree navigation
- [ ] Lists all pending review-queue entries with suggested namespace
- [ ] Namespace picker shows all 11 canonical namespaces
- [ ] Approve action: PATCH /knowledge/{id}/namespace → updates DB, removes from list
- [ ] Delete action: DELETE /knowledge/{id} → removes from DB and list
- [ ] Empty state: "Queue is clear" with appropriate message
- [ ] Count badge on nav item showing pending count
- [ ] Uses Palette.* for all colors — no bare SwiftUI colors

## Files

- `Sources/Features/ReviewQueue/ReviewQueueView.swift`
- `Sources/Features/ReviewQueue/ReviewQueueViewModel.swift`
- `Sources/Core/ContextServer/ContextServer.swift` — add PATCH /knowledge/{id}/namespace, DELETE /knowledge/{id}
