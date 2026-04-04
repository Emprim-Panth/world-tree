# TASK-118: ContextServer — GET /crew/{name}/context endpoint

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 2 — Harness Enforcement
**Agent:** Geordi
**Depends on:** TASK-113, TASK-117
**Blocks:** TASK-120

## What

New ContextServer endpoint that composes the full system prompt for a crew member at spawn time. The harness calls this before launching a Claude session. Returns: crew identity block + role boundaries + namespace access list + active scratchpad + dream knowledge digest.

## Endpoint

```
GET /crew/{name}/context?project=bim-manager&task_id=TASK-088
```

Response:
```json
{
  "crew_member": "geordi",
  "tier": 3,
  "role_title": "Architect",
  "model": "claude-sonnet-4-6",
  "system_prompt": "...(composed, ready to inject)...",
  "namespaces_write": ["bim-manager", "project-development"],
  "namespaces_read": ["bim-manager", "project-development"],
  "scratchpad_entries": [...],
  "knowledge_digest": "..."
}
```

## System Prompt Composition Order

1. **Identity block** — crew member's CLAUDE.md content (read from profile_path in crew_registry)
2. **Role boundaries block** — tier, what you can/cannot do, namespace access list (OVERRIDES identity if conflict)
3. **Bridge write protocol** — the ONLY way to save knowledge is via POST /bridge/command with type=knowledge_write or scratchpad_write. No file writes.
4. **Task context** — project name, task ID, current objective
5. **Scratchpad block** — last 7 days of this crew member's scratchpad entries
6. **Dream knowledge digest** — condensed promoted knowledge for this crew member (last 30 days, compressed)

## Model Selection

| Tier | Model returned |
|------|---------------|
| 1 (Cortana) | claude-sonnet-4-6 |
| 2 (Picard) | claude-sonnet-4-6 |
| 3 (Leads) | claude-sonnet-4-6 |
| 4 (Workers) | claude-haiku-4-5-20251001 |

## Acceptance Criteria

- [ ] Returns 404 if crew member not in registry or inactive
- [ ] Returns 400 if project maps to unknown namespace
- [ ] system_prompt is non-empty and contains identity + boundaries
- [ ] scratchpad_entries filtered to: crew_member=name AND created_at > 7 days ago AND promoted=0
- [ ] knowledge_digest is a compressed summary of promoted entries for this crew member (max 2000 chars)
- [ ] model field returns correct model string per tier
- [ ] ContextServerTests cover: valid crew, unknown crew, inactive crew, project→namespace resolution

## Files

- `Sources/Core/ContextServer/ContextServer.swift` — add route handler
- New `Sources/Core/ContextServer/CrewContextComposer.swift` — composition logic
