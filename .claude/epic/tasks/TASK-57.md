### TASK-57: Move TicketStore.scanAll() off main thread
**Epic:** Architecture
**Why:** Iterates every project directory, reads every TASK-*.md, parses with regex, and upserts to DB — all on MainActor. Blocks UI for large project sets.
**Fix:** Move file scanning to Task.detached, update published state on completion.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
