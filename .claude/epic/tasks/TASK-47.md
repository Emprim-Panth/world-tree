### TASK-47: Fix BrainFileStore file descriptor leak
**Epic:** Architecture
**Why:** `BrainFileStore.watch()` calls `open()` TWICE when fd is valid — first in the guard condition, second for the value. First fd leaks.
**Fix:** Change to `let fd = open(url.path, O_EVTONLY); guard fd != -1 else { return }`.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
