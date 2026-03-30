### TASK-48: Add WAL checkpoints for compass.db and brain-index.db
**Epic:** Database
**Why:** brain-index.db WAL is 3.2MB (4x the DB). compass.db WAL is 300KB. Neither has a checkpoint timer. WAL will grow unbounded.
**Fix:** Add checkpoint timer to CompassStore and BrainIndexer (30-second interval like DatabaseManager).

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
