# TASK-087: `world_tree_frame_screenshot` — new MCP tool for Claude Code

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Register a fourth Pencil-related MCP tool in `PluginServer.swift`: `world_tree_frame_screenshot`.

**Tool:**

```json
{
  "name": "world_tree_frame_screenshot",
  "description": "Capture a PNG screenshot of a specific Pencil design frame. Returns base64-encoded image data. Use this to visually inspect a design frame while implementing a ticket.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "frame_id":     { "type": "string", "description": "Pencil node id of the frame" },
      "pen_asset_id": { "type": "string", "description": "ID from world_tree_list_pen_assets" }
    },
    "required": ["frame_id", "pen_asset_id"]
  }
}
```

**Response:**

```json
{
  "type": "image",
  "data": "<base64-encoded PNG>",
  "mimeType": "image/png"
}
```

Follow MCP image content block spec: `{ type: "image", data: "...", mimeType: "image/png" }`.

**Implementation in PluginServer.callTool():**

```swift
case "world_tree_frame_screenshot":
    guard let frameId = args["frame_id"] as? String,
          let _ = args["pen_asset_id"] as? String else {
        return errorResponse("Missing frame_id or pen_asset_id")
    }
    let pngData = try await PencilConnectionStore.shared.client.getFrameScreenshot(frameId: frameId)
    let b64 = pngData.base64EncodedString()
    return imageContentResponse(data: b64, mimeType: "image/png")
```

Add `toolsListResponse()` entry and `callTool()` handler.

---

## Acceptance Criteria

- [ ] Tool appears in `tools/list` response
- [ ] Returns valid base64 PNG for a known frame ID
- [ ] Returns error JSON (not crash) if Pencil is disconnected
- [ ] Returns error JSON if frame_id is not found
- [ ] Claude Code can use this tool to visually inspect a design frame mid-session
- [ ] Image renders correctly when Claude Code displays the tool result

---

## Notes

- Update `WORLDTREE_MCP_TOOLS.md` with this tool after implementation (see TASK-088)
- `pen_asset_id` is accepted for validation but the screenshot comes from live Pencil — not the imported DB snapshot. It's included in the signature for discoverability/context.
