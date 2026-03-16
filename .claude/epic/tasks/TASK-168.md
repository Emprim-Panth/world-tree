# TASK-168: StreamingSectionView @State cache lost when content goes nil briefly

**Status:** open
**Priority:** medium
**Component:** Document / Streaming Render

## Problem

`StreamingSectionView` holds `@State private var cachedRaw` and `@State private var cachedRendered`. When `streamingContent` goes `nil` (even briefly — e.g. during error handling or recovery), SwiftUI destroys and recreates the view. The `@State` resets to empty strings.

When streaming resumes and `content` is re-seeded (e.g. from `attachToActiveStreamIfNeeded`), `onAppear` fires and the full content is re-parsed correctly. However there's a brief flash where either the ThinkingIndicator shows (if `streamingContent == ""`) or raw text appears before the first cache update fires.

## Fix

Move the markdown cache into a shared object (e.g. `GlobalStreamRegistry.streamCache[branchId]`) so it survives view recreation. Or: keep `@State` but seed it immediately in `init` from the passed `content` rather than waiting for `onAppear`.

## Acceptance

No flash/thesis-look when a stream recovers from a brief interruption.
