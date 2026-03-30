### TASK-58: Create shared DateParsing utility
**Epic:** Architecture
**Why:** ISO8601 date parsing with 3+ fallback strategies duplicated in 5+ locations (CompassState, AgentLabViewModel x2, HeartbeatStore, StarfleetStore).
**Fix:** Extract to `DateParsing.parseFlexible(_ str: String) -> Date?`.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
