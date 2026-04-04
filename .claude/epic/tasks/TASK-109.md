# TASK-109: Dream Engine — 3-gate trigger + 4-phase consolidation

**Status:** open
**Priority:** medium
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 4 (Knowledge Automation)
**Dependencies:** TASK-100

## What

Build `cortana-core/src/dream/index.ts` — automated background knowledge consolidation using local Ollama.

## Acceptance Criteria

- 3-gate trigger: 24h since last dream OR 5+ new scratchpad entries OR manual force via CLI
- File lock at `~/.cortana/dream/dream.lock` prevents concurrent runs
- **Phase 1 — Orient:** Read unpromoted scratchpad entries, brain/knowledge/, last 5 session summaries
- **Phase 2 — Gather:** Identify candidates — same topic 3+ times = PATTERN, uncontradicted decisions = DECISION, resolved blockers = FIX, brain entries unreferenced 30+ days = stale
- **Phase 3 — Consolidate:** Use local Ollama (qwen2.5-coder:32b) to write promoted entries to knowledge table, update under-documented projects, merge duplicates, convert relative dates to absolute
- **Phase 4 — Prune:** Mark promoted scratchpad entries (promoted=true, set promoted_to), remove brain entries stale >90 days with 0 references
- `dream_log` table records: started_at, completed_at, promoted count, pruned count, updated count, coverage_added, summary
- `shouldDream()` returns { ready, reason } for gate check
- `getDreamHistory(limit?)` returns past dream results
- All brain/ changes logged with before/after in dream.log
- **Safety:** Never auto-deletes corrections or identity files (permanent brain)
- If Ollama offline, dream is deferred (not failed)
- Zero API cost — local models only

## Key Files

- `cortana-core/src/dream/index.ts` — engine core
- `cortana-core/bin/cortana-dream.ts` — CLI (`--check`, `--force`, `--history`)
- Database: `~/.cortana/world-tree.db` (dream_log table)
- Ollama: qwen2.5-coder:32b for consolidation

## Notes

- Constitution VI defines the full knowledge lifecycle — Dream Engine is the automated middle.
- Read-only access to project files. Never modifies code.
