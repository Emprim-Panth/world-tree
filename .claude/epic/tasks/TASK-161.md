# TASK-161: MEDIUM — Ticket Truth Watchdog + Live Task Sync

**Priority**: medium
**Status**: Pending
**Category**: operations
**Epic**: Audit Follow-Up
**Sprint**: 4
**Agent**: data
**Complexity**: M

## Description

Ticket truth is still snapshot-driven. `TicketStore.scanAll()` walks `~/Development/*/.claude/epic/tasks` on launch or manual refresh, writes into `canvas_tickets`, and the UI trusts that snapshot until the next scan. That is exactly how World Tree ends up confidently showing the wrong number of open tasks.

Make ticket truth observable and self-correcting. If markdown task files change outside the app, World Tree should rescan quickly, show when data is stale, and distinguish "no tickets" from "scan hasn’t caught up."

## Files to Modify

- **Modify**: `Sources/Core/Database/TicketStore.swift`
- **Modify**: `Sources/Features/Tickets/AllTicketsView.swift`
- **Modify**: `Sources/Features/Tickets/TicketListView.swift`
- **Modify**: `Sources/Features/CommandCenter/CommandCenterViewModel.swift`
- **Create**: `Tests/DatabaseManagerTests/TicketSyncTests.swift`

## Requirements

- Watch task directories for external file changes and trigger targeted rescans
- Record and expose last successful scan time
- Show stale / scan-failed state in the ticket UI instead of silently showing old numbers
- Keep the global ticket dashboard and project ticket views in sync with the same source of truth

## Acceptance Criteria

- [ ] Editing a `TASK-*.md` file outside World Tree updates ticket counts without manual refresh
- [ ] Ticket views show last scan time or stale state
- [ ] Empty states distinguish between "no tickets" and "ticket scan unavailable"
- [ ] Command Center ticket counts update after external task-file writes
- [ ] Tests cover status changes, new task creation, and scan failure fallback
