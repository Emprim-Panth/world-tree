# TASK-098: Compose Layer — core module + tests

**Status:** open
**Priority:** critical
**Epic:** EPIC-CORTANA-HARNESS
**Phase:** 1 (Foundation)
**Dependencies:** None

## What

Build `cortana-core/src/compose/index.ts` — the single function that assembles agent context from all sources.

## Acceptance Criteria

- `compose(options: ComposeOptions)` returns `ComposedContext` with: identity, corrections, patterns, antiPatterns, projectData, scratchpad, agentSpec (if Starfleet), compiled, hash
- Project CLAUDE.md content injected as DATA under `## Project Context` header — never as top-level instructions
- Identity + corrections are NEVER truncated regardless of token budget
- Truncation order when over `maxTokens`: scratchpad first, then patterns, then projectData
- File watcher on `~/.cortana/brain/` invalidates cache on any change
- Content hash enables cache invalidation (`hash` field on `ComposedContext`)
- In-memory cache keyed by project + agent + hash
- Unit tests cover: basic compose, cache hit, cache invalidation, truncation order, agent specialization, missing project graceful fallback

## Key Files

- `cortana-core/src/compose/index.ts` — main module
- `cortana-core/src/compose/compose.test.ts` — tests
- References `~/.claude/CLAUDE.md`, `~/.cortana/brain/knowledge/`, project CLAUDE.md files

## Notes

- Default `maxTokens`: 48000
- `invalidateCache(project?)` must be exported for external callers
- Scratchpad integration will be wired in TASK-100 — use a stub/empty array for now
