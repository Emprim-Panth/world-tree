### TASK-65: Remove AppState.gatewayReachable, contextServerReachable, lastHeartbeatAt
**Why:** Written but never read by any view. Dead state.

### TASK-66: Add input_tokens/output_tokens to inference/recent response
**Why:** Data is queried from DB but dropped in JSON construction.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
