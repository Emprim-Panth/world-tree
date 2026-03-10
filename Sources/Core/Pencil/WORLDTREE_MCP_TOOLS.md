# World Tree — Pencil MCP Tools

> Reference for Claude Code sessions. Four read-only tools for connecting Pencil design frames to World Tree tickets.

---

## Tools

### `world_tree_list_pen_assets`
**"What .pen design files are attached to this project?"**

```json
{
  "name": "world_tree_list_pen_assets",
  "arguments": {
    "project": "WorldTree"
  }
}
```

Returns:
```json
[
  {
    "id": "a3f1b2c4d5e6f7a8",
    "project": "WorldTree",
    "file_name": "dashboard.pen",
    "frame_count": 5,
    "node_count": 47,
    "last_parsed": "2026-03-10T14:30:00Z"
  }
]
```

- `project` is optional — omit to list all assets across all projects.
- Returns `[]` (not an error) when no assets have been imported yet.

---

### `world_tree_get_frame_ticket`
**"What TASK does this design frame implement?"**

```json
{
  "name": "world_tree_get_frame_ticket",
  "arguments": {
    "frame_id": "frame-001",
    "pen_asset_id": "a3f1b2c4d5e6f7a8"
  }
}
```

Returns:
```json
{
  "ticket_id": "TASK-067",
  "title": "PencilMCPClient actor",
  "status": "in_progress",
  "priority": "high",
  "acceptance_criteria": "[\"Spawns binary\", \"Handles stdio\"]",
  "file_path": "/path/to/WorldTree/.claude/epic/tasks/TASK-067.md"
}
```

- Returns `null` (not an error) when no ticket link exists.
- `frame_id` is the Pencil node `id` field. `pen_asset_id` is from `world_tree_list_pen_assets`.

---

### `world_tree_list_ticket_frames`
**"What design frames implement this ticket?"**

```json
{
  "name": "world_tree_list_ticket_frames",
  "arguments": {
    "ticket_id": "TASK-067",
    "project": "WorldTree"
  }
}
```

Returns:
```json
[
  {
    "frame_id": "frame-001",
    "frame_name": "PencilMCP Client Frame",
    "file_name": "architecture.pen",
    "pen_asset_id": "a3f1b2c4d5e6f7a8"
  }
]
```

- Returns `[]` when no frames are linked to the ticket.

---

### `world_tree_frame_screenshot`
**"Show me the design for this frame"**

```json
{
  "name": "world_tree_frame_screenshot",
  "arguments": {
    "frame_id": "frame-001",
    "pen_asset_id": "a3f1b2c4d5e6f7a8"
  }
}
```

Returns an MCP **image content block** (base64 PNG):
```json
{
  "type": "image",
  "data": "<base64-encoded PNG>",
  "mimeType": "image/png"
}
```

- Requires Pencil to be running and connected.
- Returns error JSON (not a crash) if Pencil is disconnected or `frame_id` is not found.
- `pen_asset_id` is accepted for context/discoverability — screenshot comes from live Pencil, not the imported snapshot.
- Cache is invalidated on each call via this tool so you always get a fresh render.

---

## Typical Workflow

**1. Starting implementation of a ticket:**
```
I'm implementing TASK-079. What design frames should I build?
→ world_tree_list_ticket_frames { ticket_id: "TASK-079", project: "WorldTree" }
→ Open that frame in Pencil.app for visual reference
```

**2. Looking at a frame and finding its ticket:**
```
I see frame-003 in architecture.pen — what's it for?
→ world_tree_list_pen_assets { project: "WorldTree" }  // get pen_asset_id
→ world_tree_get_frame_ticket { frame_id: "frame-003", pen_asset_id: "..." }
→ Read acceptance_criteria to understand what needs building
```

**3. Starting fresh — understanding all design assets:**
```
→ world_tree_list_pen_assets { project: "WorldTree" }
→ For each asset of interest, use world_tree_list_pen_assets to browse frames
```

**4. Visually inspecting a design frame mid-implementation:**
```
1. world_tree_list_ticket_frames { ticket_id: "TASK-085", project: "WorldTree" }  // find frames
2. world_tree_frame_screenshot { frame_id: "...", pen_asset_id: "..." }            // see the design
3. Implement accordingly
```

---

## Annotation Convention

Frames get linked to tickets via the **annotation field** in the Pencil canvas.

To link a frame to `TASK-067`:
1. Select the frame in Pencil.app
2. Set the annotation/label to exactly `TASK-067` (the ticket ID, case-sensitive)
3. Import the `.pen` file into World Tree (Settings → Pencil → Import File)
4. World Tree auto-resolves the annotation to the ticket FK

The annotation must match the `id` field in `canvas_tickets` exactly (e.g. `TASK-067`, not `task-067`).

---

## Limitations

- **Filesystem watcher active (Phase 4).** World Tree watches all imported `.pen` file paths for changes. Saves auto re-import within 2 seconds of a file change — no manual re-import needed.
- **Read-only by design.** All four tools are read-only. World Tree never mutates the Pencil canvas. This is intentional — keep design authority in Pencil.
- **Project-scoped.** Ticket resolution uses the project field to avoid cross-project collisions. Always pass the correct project name.
- **Screenshot requires live Pencil.** `world_tree_frame_screenshot` requires Pencil to be running. If Pencil is offline it returns an error, not a crash.

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| All 4 tools read-only | World Tree is a memory layer, not a design editor. Canvas authority stays in Pencil. |
| Filesystem watcher via DispatchSource | Directory-level `DispatchSource.makeFileSystemObjectSource` handles rename-based saves (most editors). <2s latency with no polling. |
| Screenshot via set_selection + get_screenshot | Pencil MCP has no `get_frame_screenshot(frameId:)` — selection + global screenshot is the workaround. Switch if Pencil adds direct frame capture. |
| MCP image content block | `{"type":"image","data":b64,"mimeType":"image/png"}` — Claude Code renders this inline. Text content block would require the model to interpret base64 as text. |
| Annotation = ticket ID string | No structured metadata needed. The ticket ID is the link. Claude Code knows the ticket IDs from context. |
