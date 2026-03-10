# World Tree — Pencil MCP Tools

> Reference for Claude Code sessions. Three read-only tools for connecting Pencil design frames to World Tree tickets.

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

- **Manual import required.** World Tree links frames at import time. There's no filesystem watcher — you need to re-import the `.pen` file after design changes for links to update.
- **Read-only by design.** All three tools are read-only. World Tree never mutates the Pencil canvas. This is intentional — keep design authority in Pencil.
- **Project-scoped.** Ticket resolution uses the project field to avoid cross-project collisions. Always pass the correct project name.

---

## Decision Log

| Decision | Rationale |
|----------|-----------|
| All 3 tools read-only | World Tree is a memory layer, not a design editor. Canvas authority stays in Pencil. |
| Manual import, no watcher | Filesystem watchers add complexity and battery cost. Import on demand keeps it simple. |
| Annotation = ticket ID string | No structured metadata needed. The ticket ID is the link. Claude Code knows the ticket IDs from context. |
