# TASK-120: SessionPool spawn — inject crew role prompt at session creation

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 2 — Harness Enforcement
**Agent:** Scotty
**Depends on:** TASK-117, TASK-118
**Blocks:** TASK-121, TASK-128, TASK-140, TASK-141

## What

Modify the harness `SessionPool` (in `cortana-core/src/harness/`) to call `GET /crew/{name}/context` before spawning a Claude session and inject the returned `system_prompt` via `--system-prompt` flag (or equivalent). Workers get haiku; leads and above get sonnet.

## Current Spawn Flow

```typescript
// Current: no role injection
launchClaude(session, { project, taskId })
```

## New Spawn Flow

```typescript
// New: role-aware spawn
const ctx = await getCrewContext(crewMember, project, taskId)  // GET /crew/{name}/context
launchClaude(session, {
  model: ctx.model,
  systemPrompt: ctx.system_prompt,
  crewMember: ctx.crew_member,
  namespacesWrite: ctx.namespaces_write
})
```

## Acceptance Criteria

- [ ] `request` command to harness accepts optional `crew_member` field
- [ ] If crew_member provided: fetch context from WorldTree ContextServer, inject into spawn
- [ ] If crew_member omitted: default to 'cortana' context (CTO session)
- [ ] Model selected from context response (not hardcoded)
- [ ] system_prompt passed to claude via `--append-system-prompt` (does not replace global CLAUDE.md)
- [ ] Pool state records `crew_member` and `tier` in session entry
- [ ] `pool-state.json` updated to include crew_member per session
- [ ] If ContextServer unreachable: fail closed — do not spawn without context
- [ ] harness.log records: crew member, tier, model, namespace access list on each spawn

## Files

- `cortana-core/src/harness/index.ts` — modify launchClaude()
- `cortana-core/src/harness/index.ts` — modify request handler
- New `cortana-core/src/harness/crew-context.ts` — fetchCrewContext() function
