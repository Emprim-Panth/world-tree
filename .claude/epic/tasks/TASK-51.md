### TASK-51: Connect briefing generation to briefing-inject
**Epic:** Brain
**Why:** morning-briefing.sh sends briefings via iMessage but NEVER writes to `~/.cortana/briefings/`. briefing-inject.sh looks for files there but finds nothing. The two halves of the system don't talk to each other.
**Fix:** Add write to `~/.cortana/briefings/YYYY-MM-DD.md` in morning-briefing.sh. Re-register morning briefing LaunchAgent on Mac Studio.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
