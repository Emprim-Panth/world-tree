# TASK-084: Frame screenshot export — PencilMCPClient screenshot tool

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Extend `PencilMCPClient` with a `getFrameScreenshot(frameId: String) async throws -> Data` method that calls Pencil's MCP `getScreenshot` tool with the given frame selected.

**Flow:**

1. Call `tools/call` with `{ name: "set_selection", arguments: { nodeIds: [frameId] } }` — select the target frame
2. Call `tools/call` with `{ name: "get_screenshot", arguments: {} }` — capture PNG
3. Parse response: `result.content[0].data` is base64-encoded PNG
4. Return `Data(base64Encoded: ...)`

**Signature:**

```swift
func getFrameScreenshot(frameId: String) async throws -> Data
```

**Error cases:**
- `toolCallFailed("set_selection failed")` if selection fails
- `toolCallFailed("screenshot empty")` if response data is empty or not valid PNG
- `parseError` if base64 decode fails

---

## Acceptance Criteria

- [ ] Returns valid PNG `Data` for a known frame ID
- [ ] Returns `toolCallFailed` if `frameId` doesn't exist in the current document
- [ ] Does not leave Pencil in a modified state (selection change only — does not mutate geometry)
- [ ] Completes within 3 seconds on a local Pencil instance
- [ ] Handles Pencil not running — throws `serverUnreachable`

---

## Notes

- Selection is a UI operation, not a canvas mutation. This is still read-only from a data integrity standpoint.
- If Pencil ever adds a direct `get_frame_screenshot` tool with a `frameId` argument, switch to that and remove the selection step.
- PNG `Data` returned raw — callers handle display/caching.
