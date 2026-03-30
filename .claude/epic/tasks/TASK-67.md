### TASK-67: ContextServer — return 405 instead of 404 for wrong methods
**Why:** Incorrect HTTP semantics (minor).

### TASK-68: Reduce SessionStart injection volume
**Why:** 17+ § signals injected every session. Signals from empty directories (morning_brief, drift_alerts) waste tokens. Measure which signals influence behavior.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
