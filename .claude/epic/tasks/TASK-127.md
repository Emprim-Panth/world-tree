# TASK-127: Migration — brain/knowledge/*.md → knowledge table

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 4 — Knowledge Migration
**Agent:** Dax
**Depends on:** TASK-113, TASK-116
**Blocks:** TASK-131

## What

One-time migration script that reads the existing scattered brain knowledge files and inserts their content into the canonical `knowledge` table with correct type, namespace, and crew attribution where determinable.

## Source Files

| File | knowledge_type | Namespace heuristic |
|------|---------------|---------------------|
| `~/.cortana/brain/knowledge/corrections.md` | CORRECTION | infer from content |
| `~/.cortana/brain/knowledge/patterns.md` | PATTERN | infer from content |
| `~/.cortana/brain/knowledge/anti-patterns.md` | ANTI_PATTERN | infer from content |
| `~/.cortana/brain/knowledge/architecture-decisions.md` | DECISION | infer from content |

## Parsing Strategy

Each file uses `### Title` headers with `**Rule:**`, `**Why:**`, `**How to apply:**` sections. Parse each entry as one knowledge row:
- title = header text
- body = Rule content
- why = Why content
- how_to_apply = How to apply content
- namespace = Ollama inference from content (fall back to `review-queue` if ambiguous)
- crew_member = NULL (pre-attribution era)
- confidence = 'M' (not H — not yet verified in new system)
- promoted_from_scratchpad = 0

## Acceptance Criteria

- [ ] Script runs as: `bun cortana-core/bin/migrate-brain.ts --dry-run` (shows what would be inserted)
- [ ] `--execute` flag performs actual inserts
- [ ] Duplicate detection: skip if knowledge row with same title already exists
- [ ] Namespace inference: run each entry through Ollama with namespace list → pick best match
- [ ] Entries Ollama can't classify → namespace='review-queue'
- [ ] Output: `Migrated: N entries. Queued for review: M. Skipped (duplicate): K.`
- [ ] Source files NOT deleted by this script (TASK-132 handles deletion after verification)

## Files

- `cortana-core/bin/migrate-brain.ts` — new migration script
