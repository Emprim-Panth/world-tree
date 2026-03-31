### TASK-61: Replace manual JSON construction in ContextServer
**Epic:** ContextServer
**Why:** 10+ locations build JSON via string interpolation. Fragile, hard to maintain, risk of malformed output.
**Fix:** Define Codable response structs, use JSONEncoder for all responses.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
