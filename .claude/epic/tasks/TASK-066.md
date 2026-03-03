# TASK-066: feat: Spatial computing / Vision (visionOS + Mac spatial view)

**Status:** Done
**Priority:** Low
**Assignee:** Unassigned
**Created:** 2026-03-03
**Updated:** 2026-03-03

---

## Description

Vision Pro: immersive conversation environment with floating branch windows.
Mac/iPad: Ornament-style floating panel for secondary branch view (no headset needed).

## visionOS Features (requires Vision Pro hardware)

- [ ] Conversation windows as floating volumes in space
- [ ] Gaze + pinch to select branches
- [ ] Spatial audio for streaming response (voice plays from "Cortana's location")
- [ ] Ornament accessory panel showing branch tree

## Mac/iPad Equivalent (no Vision Pro required)

- [ ] Stage Manager-aware multi-window layout
- [ ] Floating inspector panel (using `inspector(isPresented:)` on iPad)
- [ ] Picture-in-picture style streaming indicator overlay
- [ ] macOS: multiple NSWindow instances for parallel branches
- [ ] iPad: UISplitViewController 3-column layout (already exists on iPad)

## Acceptance Criteria

- [ ] visionOS target conditionally compiled (`#if os(visionOS)`)
- [ ] Mac multi-window: "Open in New Window" menu item per branch
- [ ] iPad inspector panel showing branch metadata during conversation
- [ ] No regressions on iPhone or macOS

## Implementation Notes

- visionOS: `WindowGroup` + `ImmersiveSpace` (need Vision Pro to test)
- Mac: `openWindow(id:)` environment action for branch windows
- iPad inspector: `.inspector(isPresented: $showInspector)` in SwiftUI
- Stage Manager compatibility: `UISceneActivationConditions` configuration
