### TASK-43: Fix ContextServer body truncation at 64KB
**Epic:** ContextServer
**Why:** Single-read of 65536 bytes means any POST body > 64KB silently fails. No timeout on connections (slowloris risk). No connection limit.
**Fix:** Accumulate reads until Content-Length satisfied or isComplete. Add 30s connection deadline. Add 50-connection limit.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
