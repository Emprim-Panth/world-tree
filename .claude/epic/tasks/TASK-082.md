# TASK-082: Dax — Phase 3 knowledge capture: MCP tool contracts + integration guide

**Status:** Pending
**Priority:** medium
**Assignee:** Dax
**Phase:** 3 — World Tree MCP Tools
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Two deliverables:

**1. `Sources/Core/Pencil/WORLDTREE_MCP_TOOLS.md`** — Claude Code-facing reference for using World Tree's Pencil tools in a session:
- How to use each of the 3 new tools (example `tools/call` invocations)
- Workflow: "I'm implementing TASK-079. What frame should I build?" → `world_tree_list_ticket_frames` → open that frame in Pencil
- Frame-to-ticket annotation convention: how to write `"TASK-067"` in a Pencil frame's annotation field so World Tree auto-links it on next import
- Limitations: World Tree only knows about .pen files explicitly imported. No filesystem watcher (future task).
- Decision log: why all 3 tools are read-only (World Tree never mutates Pencil canvas state)

**2. Update `ARCHITECTURE.md`** — add "Pencil Intelligence Layer" section after existing "Planned Extensions" phases:
- Three-phase architecture description
- New modules (`Sources/Core/Pencil/`)
- New database tables (`pen_assets`, `pen_frame_links`)

Memory log entries to execute after verification:
```bash
cortana-cli memory log "[PATTERN] World Tree Pencil tools: world_tree_list_pen_assets, world_tree_get_frame_ticket, world_tree_list_ticket_frames — use these in any Claude Code session to connect design frames to tickets"
cortana-cli memory log "[DECISION] All 3 World Tree Pencil MCP tools are read-only — World Tree never mutates Pencil canvas state"
```

---

## Acceptance Criteria

- [ ] `WORLDTREE_MCP_TOOLS.md` committed with all 3 tools documented + example JSON
- [ ] `ARCHITECTURE.md` Pencil section present and accurate
- [ ] Annotation convention clearly explained (how to write `TASK-067` in Pencil metadata)
- [ ] Memory log commands listed in the doc for future sessions to replay
- [ ] `WORLDTREE_MCP_TOOLS.md` is written for Claude Code — concise, tool-first, no filler

---

## Context

**Why this matters:** Dax closes the loop. After this, any future Claude Code session can look up these docs and use the tools without re-researching anything. The institutional memory is permanent.

**Related:** TASK-079, TASK-080, TASK-081 (all must be complete first)

---

## Handoff History

| Time | Agent | Action |
|------|-------|--------|
| 2026-03-10 | Spock | Created task |

---

## Blockers

*Depends on: TASK-079, TASK-080, TASK-081*
