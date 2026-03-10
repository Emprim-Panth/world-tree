# TASK-088: Phase 4 docs — update WORLDTREE_MCP_TOOLS.md + ARCHITECTURE.md

**Status:** Done
**Priority:** medium
**Assignee:** Dax
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Two deliverables after Phase 4 implementation is complete:

**1. Update `Sources/Core/Pencil/WORLDTREE_MCP_TOOLS.md`**

Add `world_tree_frame_screenshot` tool:

```markdown
### `world_tree_frame_screenshot`
**"Show me the design for this frame"**

{
  "name": "world_tree_frame_screenshot",
  "arguments": {
    "frame_id": "frame-001",
    "pen_asset_id": "a3f1b2c4d5e6f7a8"
  }
}

Returns: image content block (base64 PNG). Display inline.

Typical workflow:
1. world_tree_list_ticket_frames { ticket_id: "TASK-085" }  // find frames
2. world_tree_frame_screenshot { frame_id: ..., pen_asset_id: ... }  // see the design
3. Implement accordingly
```

Add filesystem watcher note to Limitations section:
- Phase 4 adds filesystem watcher — `.pen` changes auto re-import within 2 seconds.

**2. Update `ARCHITECTURE.md` Pencil section**

- Change Phase 4 row from `← Next` to `✓ Done`
- Add filesystem watcher to Design Invariants section
- Add `world_tree_frame_screenshot` to MCP Tools table

**3. Mark TASK-083 through TASK-087 Done in their `.md` files**

---

## Acceptance Criteria

- [ ] `WORLDTREE_MCP_TOOLS.md` includes `world_tree_frame_screenshot` with example
- [ ] `ARCHITECTURE.md` Phase 4 marked Done
- [ ] TASK-083..087 all have `**Status:** Done`
- [ ] Commit message: `docs(pencil): Phase 4 complete — visual verify + filesystem watcher`

---

## Notes

Run memory log entries after verification:
```bash
cortana-cli memory log "[PATTERN] World Tree Pencil Phase 4 — frame screenshots via PencilMCPClient.getFrameScreenshot, watcher via DispatchSource, visual diff via CGWindowListCreateImage"
cortana-cli memory log "[DECISION] world_tree_frame_screenshot returns MCP image content block (type:image, data:base64, mimeType:image/png) — Claude Code renders inline"
```
