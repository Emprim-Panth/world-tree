# TASK-131: Migration verification — row counts, spot checks, mirror generation

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 4 — Knowledge Migration
**Agent:** Worf
**Depends on:** TASK-127, TASK-128, TASK-129, TASK-130
**Blocks:** TASK-132

## What

Before any source files are deleted, verify the migration is complete and correct. This is Worf's gate — nothing gets deleted until this passes.

## Verification Steps

### 1. Row Count Audit

Run against the DB and compare to expected minimums:

| Source | Expected minimum rows |
|--------|----------------------|
| brain/knowledge/*.md | 30 entries |
| crew knowledge/ dirs | 200 entries |
| game dev vaults | 150 entries |
| crew MEMORY.md files | 50 scratchpad + 100 knowledge |
| **Total knowledge table** | **500+ rows** |

### 2. Namespace Distribution

```sql
SELECT namespace, COUNT(*) FROM knowledge GROUP BY namespace ORDER BY COUNT(*) DESC;
```

Every namespace except `review-queue` should have at least some entries. `game-dev` should have 150+.

### 3. Crew Attribution

```sql
SELECT crew_member, COUNT(*) FROM knowledge GROUP BY crew_member;
```

Every active crew member with knowledge dirs should appear.

### 4. Spot Check — 10 Random Entries

Pull 10 random knowledge rows, verify:
- title makes sense
- body is non-empty and coherent
- namespace matches content
- No malformed JSON or truncation artifacts

### 5. Human-Readable Mirror Integrity

After promotion step, verify mirrors exist for promoted entries:
- `~/.cortana/starfleet/crew/geordi/knowledge/*.md` still readable
- No binary garbage, encoding issues

## Acceptance Criteria

- [ ] Total knowledge rows ≥ 500
- [ ] game-dev namespace rows ≥ 150
- [ ] All 11 namespaces represented (except review-queue may be empty)
- [ ] All active crew members attributed in at least 1 row
- [ ] 10/10 spot checks pass manual review
- [ ] Mirror files readable and correctly formatted
- [ ] Verification report written to `~/.cortana/logs/migration-verification.md`

## Files

- `cortana-core/bin/verify-migration.ts` — runs all checks, outputs report
