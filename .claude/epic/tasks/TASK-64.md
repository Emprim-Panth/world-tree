### TASK-64: Extract FileWatcher utility
**Why:** DispatchSource file-watching pattern repeated in 4 files.

### TASK-65: Remove AppState.gatewayReachable, contextServerReachable, lastHeartbeatAt
**Why:** Written but never read by any view. Dead state.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
