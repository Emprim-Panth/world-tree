# TASK-119: Bridge validation — namespace write enforcement + audit log

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-AGENT-OS
**Phase:** 2 — Harness Enforcement
**Agent:** Geordi
**Depends on:** TASK-113, TASK-115, TASK-116, TASK-117
**Blocks:** TASK-121, TASK-125

## What

The bridge's `POST /bridge/command` handler for `knowledge_write` must validate the crew member's namespace access before committing. Every attempt — successful or blocked — is logged to `knowledge_write_log`. This is the enforcement core.

## Validation Logic

```
1. crew_member in crew_registry and active? → else 400
2. namespace in namespaces table? → else 400 (unknown namespace)
3. namespace in crew_registry.namespaces_write for this crew? → else 403 BLOCKED
4. knowledge_type valid enum value? → else 400
5. title + body non-empty? → else 400
6. All checks pass → INSERT into knowledge, INSERT into knowledge_write_log (blocked=0)
7. Any check fails after crew verified → INSERT into knowledge_write_log (blocked=1, reason=...)
```

## Request Format

```json
{
  "type": "knowledge_write",
  "session_id": "abc123",
  "crew_member": "geordi",
  "namespace": "world-tree",
  "knowledge_type": "PATTERN",
  "title": "Use available_height() not clip_rect().height()",
  "body": "...",
  "why": "clip_rect includes frame margins...",
  "how_to_apply": "In TopBottomPanel.show() closure..."
}
```

## Response

Success (201):
```json
{"ok": true, "id": "uuid", "namespace": "world-tree"}
```

Blocked (403):
```json
{"ok": false, "error": "namespace_denied", "message": "geordi cannot write to 'bim-manager'. Assigned namespace: 'world-tree'."}
```

## Acceptance Criteria

- [ ] Valid write → knowledge row inserted, audit log row inserted (blocked=0)
- [ ] Wrong namespace → 403, audit log row inserted (blocked=1), knowledge NOT inserted
- [ ] Unknown crew → 400, no audit log (cannot attribute)
- [ ] Unknown namespace → 400, audit log with reason
- [ ] Invalid knowledge_type → 400
- [ ] Missing required fields → 400
- [ ] Cortana (tier 1, namespaces_write=["*"]) can write to any namespace
- [ ] Garak (read-only) gets 403 on any write attempt
- [ ] Test: 10 blocked attempts for Geordi trying to write to bim-manager — all logged, none committed

## Files

- `Sources/Core/ContextServer/ContextServer.swift` — extend handlePostBridgeCommand
- `Sources/Core/Database/KnowledgeStore.swift` — new file, write + audit log operations
