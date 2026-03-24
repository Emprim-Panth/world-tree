# TASK-21: Wire SessionStart hook to pull from ContextServer

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 4 — Integration
**Depends on:** TASK-20

## Context

cortana-core's SessionStart hook currently injects context from compass + BRAIN.md via direct file reads. This task updates the hook to instead call World Tree's ContextServer, getting a pre-compressed brief.

## Where to Edit

cortana-core HookProcessor, `SessionStart` handler. Likely in:
`~/Development/cortana-core/src/hooks/session-start.ts`
(verify path before editing)

## Required Change

Replace direct BRAIN.md reads with a ContextServer call:

```typescript
async function injectProjectContext(project: string): Promise<string> {
  const token = loadGatewayToken()  // reads ark-gateway.toml

  try {
    const res = await fetch(`http://127.0.0.1:4863/context/${project}`, {
      headers: { 'x-cortana-token': token },
      signal: AbortSignal.timeout(2000)  // 2s timeout — don't block session start
    })

    if (!res.ok) {
      // Fall back to direct BRAIN.md read if ContextServer is down
      return await readBrainMdDirect(project)
    }

    const brief = await res.json()
    return formatBrief(brief)  // formats as markdown for injection

  } catch {
    // ContextServer not running — fall back to direct read
    return await readBrainMdDirect(project)
  }
}
```

**Fallback is critical:** If World Tree isn't running (crash, rebuild, startup), the session must still work via direct BRAIN.md read. Never hard-depend on ContextServer.

## Formatted Brief Output

```
## Project Context: {project}
**Phase:** {phase}
**Milestone:** {milestone}

{brain_excerpt}

**Open tickets ({count}):**
{open_tickets joined by newline}

**Recent crew work:**
{recent_dispatches}
```

## Acceptance Criteria

- [ ] Read cortana-core session-start handler before editing
- [ ] SessionStart calls ContextServer with 2s timeout
- [ ] Falls back to direct BRAIN.md read if ContextServer unavailable
- [ ] Injected context is < 1500 tokens (validate with rough char count)
- [ ] No session start delay > 3 seconds total
- [ ] Test: start a session for BookBuddy, verify context appears in system prompt

## Notes

This task requires cortana-core to be edited, not World Tree. Make sure you're in the right repo. Test by running `claude` in a project directory and confirming the injected context appears.
