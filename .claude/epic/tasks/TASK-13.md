# TASK-13: Delete Database chat stores and trim MigrationManager

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 1 — Deletion
**Depends on:** TASK-12

## Context

13 of the 17 DatabaseManager stores exist solely to support the chat system. Delete them all. Trim MigrationManager to only contain the 3 migrations we need: canvas_tickets, canvas_dispatches, and the new cleanup migration to drop orphaned tables.

## Files to Delete

```
Core/Database/AgentStatusStore.swift
Core/Database/AttentionStore.swift
Core/Database/AutoDecisionStore.swift
Core/Database/ConflictDetector.swift
Core/Database/DiffReviewStore.swift
Core/Database/EventRuleStore.swift
Core/Database/GraphStore.swift
Core/Database/MessageStore.swift
Core/Database/PenAssetStore.swift
Core/Database/TimelineStore.swift
Core/Database/TokenStore.swift
Core/Database/TreeStore.swift
Core/Database/UIStateStore.swift
```

## Files to Keep

```
Core/Database/DatabaseManager.swift
Core/Database/CompassStore.swift
Core/Database/HeartbeatStore.swift
Core/Database/TicketStore.swift
Core/Database/SessionStateStore.swift
Core/Database/MigrationManager.swift    ← heavily trimmed (see below)
```

## Also Delete — Core Models

```
Core/Models/AgentFileTouch.swift
Core/Models/AgentSession.swift
Core/Models/AttentionEvent.swift
Core/Models/Branch.swift
Core/Models/ConversationTree.swift
Core/Models/DaemonStatus.swift
Core/Models/EventRule.swift
Core/Models/GlobalSearchResult.swift
Core/Models/Message.swift
Core/Models/NERVEModels.swift
Core/Models/ProposedWorkArtifact.swift
Core/Models/SessionHealth.swift
Core/Models/StarfleetRoster.swift
Core/Models/TokenAggregates.swift
Core/Models/ToolActivity.swift
Core/Models/UnifiedTimelineEvent.swift
```

## MigrationManager — Required Edits

After deletion, read MigrationManager.swift and trim it to only these migrations:
1. `v1_canvas_tickets` — CREATE TABLE canvas_tickets
2. `v2_canvas_dispatches` — CREATE TABLE canvas_dispatches
3. **Add new:** `v3_drop_chat_tables` — DROP TABLE IF EXISTS for canvas_trees, canvas_branches, canvas_jobs, pen_assets, pen_frame_links

All other migration registrations must be removed from the file.

## Gateway Models — Also Delete

```
Core/Gateway/FactoryStore.swift
Core/Gateway/CortanaOpsStore.swift
```

Keep: `Core/Gateway/GatewayClient.swift`, `Core/Gateway/NERVEClient.swift`

## Acceptance Criteria

- [ ] All listed files deleted
- [ ] MigrationManager.swift trimmed to 3 migrations only
- [ ] v3_drop_chat_tables migration added
- [ ] Core/Models/ contains only Dispatch.swift after this task
- [ ] Core/Gateway/ contains only GatewayClient.swift and NERVEClient.swift

## Notes

Read MigrationManager.swift before editing. The v3 migration must use `DROP TABLE IF EXISTS` (not `DROP TABLE`) — the tables may not exist on fresh installs.
