# TASK-24: Wire PreCompact hook to ContextServer (within-session compaction resilience)

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 4 — Integration
**Depends on:** TASK-20

## Context

PreCompact hook fires just before Claude Code compacts the context window. Currently it reinjects hivemind, alerts, and session state. This task adds a ContextServer call so the compact summary includes a fresh project brief — meaning after compaction the session retains project essentials without re-asking Evan.

Without this, the epic eliminates between-session knowledge loss but within-session compaction still causes disorientation. With this, compaction becomes genuinely irrelevant.

## Where to Edit

cortana-core HookProcessor, `PreCompact` handler. Likely:
`~/Development/cortana-core/src/hooks/pre-compact.ts`
(verify path before editing)

## Required Change

```typescript
async function injectContextBeforeCompaction(sessionId: string): Promise<string> {
  const project = await getSessionProject(sessionId)  // from session state
  if (!project) return ''

  const token = loadGatewayToken()

  try {
    const res = await fetch(`http://127.0.0.1:4863/context/${project}`, {
      headers: { 'x-cortana-token': token },
      signal: AbortSignal.timeout(2000)
    })

    if (!res.ok) return ''

    const brief = await res.json() as ProjectBrief

    return [
      `<context-refresh project="${project}" injected-at="${new Date().toISOString()}">`,
      `Phase: ${brief.phase}`,
      `Milestone: ${brief.milestone}`,
      ``,
      brief.brain_excerpt,
      ``,
      `Open tickets:`,
      brief.open_tickets.slice(0, 5).join('\n'),
      `</context-refresh>`
    ].join('\n')

  } catch {
    return ''  // never block compaction
  }
}
```

This injected block appears just before the compaction fires. Claude Code's compaction summarizer sees it and includes it in the compact summary. Post-compaction context retains the essentials.

## What This Proves

After this task, run Proof 4 from the analysis:

```
Setup: Run a long session on any project until compaction fires
Observe: Does the session retain project phase and current task after compaction?
Pass: Session continues without asking "where were we?" or losing project orientation
Fail: Session asks re-orienting questions or forgets the current task
```

## Acceptance Criteria

- [ ] Read PreCompact handler before editing
- [ ] ContextServer call added with 2s timeout
- [ ] Injected block is < 500 tokens (it's in addition to existing PreCompact injections)
- [ ] Never blocks compaction — wrapped in try/catch, fire-and-forget if ContextServer is down
- [ ] Post-compaction: session retains project name, phase, and current milestone
- [ ] Test: force a long session to compact, verify orientation is retained

## Notes

The injected block should be labeled (`<context-refresh>`) so the compaction summarizer can identify it as high-priority context to preserve in the summary. Most LLM summarizers preserve explicitly labeled blocks.
