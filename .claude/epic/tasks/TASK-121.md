# TASK-121: Scratchpad write via bridge — namespace + crew tags

**Status:** open
**Priority:** high
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 2 — Harness Enforcement
**Agent:** Geordi
**Depends on:** TASK-114, TASK-119
**Blocks:** TASK-122, TASK-123

## What

Extend the bridge `POST /bridge/command` handler to support `scratchpad_write` — the working memory write for crew members during sessions. Scratchpad writes are lower-friction than knowledge writes (no type, no why/how) but still namespace-validated.

## Request Format

```json
{
  "type": "scratchpad_write",
  "session_id": "abc123",
  "crew_member": "worf",
  "namespace": "archon-cad",
  "content": "Ribbon height: use available_height() not clip_rect(). Off by 6px otherwise."
}
```

## Validation

- crew_member must exist in crew_registry
- namespace must be in crew's namespaces_write (same enforcement as knowledge_write)
- content non-empty
- Blocked writes logged to knowledge_write_log

## Response

Success (201):
```json
{"ok": true, "id": "uuid", "expires_at": "2026-04-09T..."}
```

## Expiry

Scratchpad entries have an implicit 7-day TTL. `expires_at` = created_at + 7 days. The prune step (TASK-126) deletes expired unpromoted entries.

## Acceptance Criteria

- [ ] Valid scratchpad write → row inserted with crew_member, namespace, session_id, created_at
- [ ] promoted=0, promoted_at=NULL on creation
- [ ] Namespace validation same as knowledge_write (403 if wrong namespace)
- [ ] expires_at computed and returned (not stored — computed from created_at + 7d)
- [ ] GET /crew/{name}/context returns scratchpad entries created in last 7 days for this crew member
- [ ] Test: Worf writes to archon-cad (valid) ✓, Worf writes to bim-manager (invalid) → 403 logged

## Files

- `Sources/Core/ContextServer/ContextServer.swift` — extend handlePostBridgeCommand
- `Sources/Core/Database/ScratchpadStore.swift` — add write with crew/namespace tags
