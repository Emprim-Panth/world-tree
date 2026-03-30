### TASK-54: Fix knowledge-promote.sh expire function
**Epic:** Brain
**Why:** The `expire` command logs expired candidates but never actually deletes them. The deletion sed command is missing.
**Fix:** Add sed deletion after the logging loop.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
