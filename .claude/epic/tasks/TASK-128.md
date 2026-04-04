# TASK-128: Migration — crew knowledge/ dirs → knowledge table

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 4 — Knowledge Migration
**Agent:** Dax
**Depends on:** TASK-113, TASK-116, TASK-117, TASK-120
**Blocks:** TASK-131

## What

One-time migration that reads every crew member's `~/.cortana/starfleet/crew/{name}/knowledge/` directory and inserts the content into the `knowledge` table with crew attribution. This is the richest existing knowledge — already well-organized and crew-attributed.

## Source Structure

```
~/.cortana/starfleet/crew/{name}/knowledge/
├── craft/       → type inferred from content
├── systems/     → type inferred
├── patterns/    → PATTERN
├── vocabulary/  → OBSERVATION
├── reference/   → OBSERVATION
├── decisions/   → DECISION
└── *.md         → type inferred
```

## Per-Crew Migration

For each crew member in crew_registry:
1. Walk their `knowledge/` dir recursively
2. For each .md file: parse content, extract title from `# Header` or filename
3. Infer namespace from file content via Ollama (or from known file names like `archon-cad-qa-lessons.md` → `archon-cad`)
4. Infer knowledge_type from subdirectory name and content
5. Insert with crew_member = crew name

## Special Cases

- `MEMORY.md`, `KNOWLEDGE.md`, `MEMORY.md` at crew root — skip (handled by TASK-130)
- `*_VAULT.md` files — handled by TASK-129 (game dev vaults)
- `BOOT.md`, `IDENTITY.md` — skip (identity docs, not knowledge entries)

## Acceptance Criteria

- [ ] All crew members processed
- [ ] Each .md file becomes 1+ knowledge rows (split on `---` separator if file contains multiple entries)
- [ ] crew_member correctly attributed
- [ ] namespace inferred or falls to review-queue
- [ ] Dry-run mode shows plan before execution
- [ ] Output per crew member: `{name}: N files → M rows. K queued for review.`
- [ ] Source files NOT deleted by this script

## Files

- `cortana-core/bin/migrate-crew.ts` — new script, reuses namespace inference from TASK-127
