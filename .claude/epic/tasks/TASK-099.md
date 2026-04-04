# TASK-099: Compose Layer — hook integration

**Status:** open
**Priority:** critical
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 1 (Foundation)
**Dependencies:** TASK-098

## What

Replace raw CLAUDE.md reads in `cortana-hooks` SessionStart with Compose Layer output. Hooks call `compose()` instead of manually assembling context from brain files.

## Acceptance Criteria

- `cortana-hooks` SessionStart calls `compose()` and injects the `compiled` field as system context
- Raw brain file reads removed from hook path
- Project CLAUDE.md is read by Compose Layer, not by hooks directly
- Hook still exits 0 on any failure (falls back to raw CLAUDE.md if compose fails)
- Existing session behavior is identical from the agent's perspective — same information, better assembly
- No performance regression: hook completion < 500ms

## Key Files

- `cortana-core/src/hooks/` — session start hook
- `cortana-core/src/compose/index.ts` — compose function (from TASK-098)

## Notes

- This is the cutover point. After this task, all sessions get context from Compose Layer.
- Project CLAUDE.md files remain unchanged — they're now data inputs, not instruction overrides.
