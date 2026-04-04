# TASK-123: Dream Engine — promote scratchpad to knowledge + crew knowledge dir

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 3 — Dream Engine
**Agent:** Dax
**Depends on:** TASK-122
**Blocks:** TASK-138

## What

The promote step of the dream cycle. High-confidence, unambiguous scratchpad groups become permanent knowledge entries in the DB and are mirrored as human-readable .md files in the crew member's knowledge directory.

## Promotion Criteria (group must meet ALL)

- Confidence score: H (not M or L)
- Not a near-duplicate of existing knowledge entry (cosine similarity < 0.85)
- Namespace is unambiguous (not review-queue candidate)
- At least 1 scratchpad entry in the group (no phantom promotions)

## Promotion Action

```
1. INSERT into knowledge table:
   - namespace = group's namespace
   - crew_member = the crew member
   - type = inferred (PATTERN/CORRECTION/DECISION based on content analysis)
   - title, body, why, how_to_apply = extracted by Ollama from grouped content
   - confidence = 'H'
   - promoted_from_scratchpad = 1
   - source_session = originating session_id

2. UPDATE scratchpad entries: promoted=1, promoted_at=now()

3. Write human-readable mirror:
   ~/.cortana/starfleet/crew/{name}/knowledge/{namespace}/{slug}.md
   Format: standard crew knowledge file with Rule/Why/How to apply

4. If type=CORRECTION or type=PREFERENCE:
   → TASK-125 profile update (append to crew CLAUDE.md memory section)
```

## Acceptance Criteria

- [ ] Only H-confidence groups promoted
- [ ] Duplicate check runs before every promotion
- [ ] Promoted scratchpad entries marked promoted=1
- [ ] knowledge row inserted with all required fields populated by Ollama extraction
- [ ] Human-readable mirror file created at correct path
- [ ] Mirror file uses crew's established knowledge format (matches existing files in their knowledge/ dir)
- [ ] Test: simulate 5 high-confidence scratchpad entries → verify knowledge row + mirror file created

## Files

- `cortana-core/src/dream/promote.ts`
- `cortana-core/src/dream/mirror.ts` — writes human-readable mirrors
