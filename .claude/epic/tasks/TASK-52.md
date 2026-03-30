### TASK-52: Add Compass/Ticket API endpoints to ContextServer
**Epic:** ContextServer
**Why:** Core World Tree data (compass state, tickets) has no HTTP API. CLI tools and remote agents must go directly to SQLite files. Blocks mobile/remote access.
**Fix:** Add GET /compass/{project}, GET /compass/overview, GET /tickets/{project}, POST /alerts, PATCH /alerts/{id}.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
