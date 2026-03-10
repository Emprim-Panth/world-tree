# TASK-068: PencilModels.swift — Swift value types for Pencil's .pen JSON schema

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Define `Codable` Swift structs matching Pencil's .pen JSON node tree under `Sources/Core/Pencil/PencilModels.swift`:

```
PencilDocument       — top-level .pen file (version, nodes: [PencilNode])
PencilNode           — id, type, x, y, width, height, fill, stroke, children: [PencilNode], components: [String]
PencilFrame          — subtype of PencilNode where type == "frame", adds: name, annotation (optional ticket reference)
PencilVariable       — name, value, type (color/number/string)
PencilLayout         — frames: [PencilFrame], viewport: PencilViewport
PencilEditorState    — currentFile: String?, selectedNodeIds: [String], zoom: Double
PencilBatchResult    — success: Bool, applied: Int, errors: [String]
```

The `annotation` field on `PencilFrame` is the hook for Phase 2 frame-to-ticket linking. It holds an optional string of the form `"TASK-067"` written into the .pen file node metadata.

Use lenient decoding — all fields except `id` and `type` are optional. Unknown fields are silently ignored. This protects against Pencil schema changes.

---

## Acceptance Criteria

- [ ] All structs are `Codable`, `Sendable`, and equatable
- [ ] `PencilDocument` round-trips through `JSONEncoder` / `JSONDecoder` without loss
- [ ] A test fixture `.pen` file (committed to `Tests/Fixtures/sample.pen`) decodes correctly into `PencilDocument`
- [ ] No SwiftUI, GRDB, or Foundation imports beyond `Foundation` itself
- [ ] Unknown node types decode as `.unknown` (no crash on new Pencil types)

---

## Context

**Why this matters:** These are the shared types used by every component in the Pencil layer — client, store, UI, and MCP tools. They must be stable before Phase 2 schema design locks in.

**Note:** Can be developed in parallel with TASK-067.

**Related:** TASK-067 (client uses these), TASK-069 (store uses these), TASK-074 (DB schema derived from these)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*No blockers*
