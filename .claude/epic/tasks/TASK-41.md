### TASK-41: Drop broken triggers and duplicate FTS indexes
**Epic:** Database
**Why:** Every message INSERT fires triggers referencing dropped `canvas_trees`/`canvas_branches` tables + duplicate FTS triggers cause double-indexing of all 19,921 messages. Silent overhead on every write.
**Fix:** Add v39 migration: drop `canvas_trees_msg_insert`, `canvas_trees_msg_delete` triggers, drop duplicate `messages_ai`/`messages_ad`/`messages_au` triggers, rebuild FTS index, drop `canvas_branch_tags` table, drop duplicate `idx_kd_domain` index.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
