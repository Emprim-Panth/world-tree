### TASK-62: BrainIndexer search performance — cache embeddings
**Epic:** Database
**Why:** Loads ALL embeddings into memory (full table scan) on every search query. Currently 89 chunks, will degrade at 1000+.
**Fix:** Cache embeddings in memory after indexAll(). Invalidate on re-index. Consider sqlite-vss for vector search.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
