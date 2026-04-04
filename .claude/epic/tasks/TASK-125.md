# TASK-125: Dream Engine — crew profile update on CORRECTION/PREFERENCE promotion

**Status:** open
**Priority:** medium
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 3 — Dream Engine
**Agent:** Dax
**Depends on:** TASK-123
**Blocks:** TASK-138

## What

When a CORRECTION or PREFERENCE is promoted to the knowledge table, it should also be appended to the crew member's `CLAUDE.md` memory section. This makes the correction part of the crew member's identity — they carry it into every future session without needing it injected from the DB every time.

## Target Location

```
~/.cortana/starfleet/crew/{name}/CLAUDE.md
```

Append to the existing memory section, or create one if absent:

```markdown
## Memory — Session Learnings

### {title}
**Rule:** {body}
**Why:** {why}
**How to apply:** {how_to_apply}
*Promoted: {promoted_at}*
```

## Acceptance Criteria

- [ ] Only CORRECTION and PREFERENCE types trigger profile update (not PATTERN, DECISION, etc.)
- [ ] Append-only — never overwrites existing CLAUDE.md content
- [ ] Creates `## Memory — Session Learnings` section if not present
- [ ] Idempotent — re-running dream does not duplicate the entry (check for title match before appending)
- [ ] Backup of CLAUDE.md taken before write: `{name}.CLAUDE.md.bak` (overwritten each dream run, not accumulated)
- [ ] Test: promote a CORRECTION → verify CLAUDE.md has new entry, verify idempotency on second run

## Files

- `cortana-core/src/dream/profile-update.ts`
