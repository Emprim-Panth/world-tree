### TASK-50: Deduplicate HeartbeatStore sync/async refresh
**Epic:** Architecture
**Why:** 280 lines of nearly identical code (sync `refresh()` and `fetchAllAsync()`). Maintenance burden — bugs fixed in one aren't fixed in the other.
**Fix:** Delete sync `refresh()`, keep only `refreshAsync()`. Update callers.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
