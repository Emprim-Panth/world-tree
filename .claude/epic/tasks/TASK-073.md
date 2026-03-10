# TASK-073: Dax — Phase 1 knowledge capture: Pencil MCP protocol documentation

**Status:** Pending
**Priority:** medium
**Assignee:** Dax
**Phase:** 1 — MCP Client
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Create `Sources/Core/Pencil/PENCIL_PROTOCOL.md` — the authoritative in-repo reference for all future sessions working on this layer.

Must document:

1. **JSON-RPC 2.0 envelope structure** for each of Pencil's 7 MCP tools (request + response shapes, inferred from research and live testing during TASK-067)
2. **The .pen file format:** top-level schema, node type taxonomy, how children and components arrays nest, what `annotation` carries
3. **Observed quirks and gotchas** (e.g. which tools are read-only vs. mutating, whether `batch_design` is safe to call from World Tree)
4. **Decision log:** why World Tree does NOT use `batch_design` or `set_variables` — read-only consumer policy, deliberate architectural constraint to avoid corrupting canvas state during live Claude Code sessions

Memory log entries to execute after this task is verified:
```bash
cortana-cli memory log "[DECISION] World Tree is a read-only consumer of Pencil MCP — never calls batch_design or set_variables to avoid corrupting canvas state during live Claude Code sessions"
cortana-cli memory log "[PATTERN] Pencil MCP client follows GatewayClient actor pattern: URLSession, 15s/60s timeouts, no @MainActor on actor itself"
```

---

## Acceptance Criteria

- [ ] `PENCIL_PROTOCOL.md` is complete and committed
- [ ] All 7 tools documented with request/response JSON examples
- [ ] Decision log section present with rationale for read-only policy
- [ ] Memory log commands listed in the doc so any future session can replay them
- [ ] `.pen` node schema documented with all field types and optionality

---

## Context

**Why this matters:** Dax is the institutional memory. Without this doc, every future session has to re-research the Pencil protocol from scratch. This pays forward permanently.

**Related:** TASK-067 (client implementation informs docs), TASK-068 (model types documented here)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-067, TASK-068 (to accurately document the protocol)*
