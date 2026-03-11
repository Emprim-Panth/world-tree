# TASK-092: CRITICAL — AppState @State wrapper duplicates singleton + silent DB init failure

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Verified correct — AppState uses @Observable macro, @State is the right wrapper. DB error handling already surfaces NSAlert.
**Priority:** critical
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Two related issues in app initialization:

### 1. @State wrapping singleton (WorldTreeApp.swift:6)
```swift
@State private var appState = AppState.shared
```
`@State` creates a property wrapper around the singleton. Since AppState is `@Observable`, the @State wrapper is unnecessary and can cause state propagation issues. Changes to `AppState.shared` may not update the @State copy.

### 2. Silent database initialization failure (AppState.swift:48-58)
Database setup happens in `AppState.init()`. If setup throws, error is stored in `dbSetupError` but the app continues running with `dbPool = nil`. All subsequent database queries fail silently, returning empty results or false.

### 3. DB init race (AppState.swift:49-58)
Child views can fire `onAppear` before database setup completes. DocumentEditorViewModel retries 10x250ms but silently fails after 2.5 seconds.

## Acceptance Criteria

- [ ] Remove `@State` wrapper: use `let appState = AppState.shared` or access directly
- [ ] DB setup failure shows blocking error immediately (not just onAppear alert)
- [ ] DB readiness is an observable property that views wait on before rendering
- [ ] Child views don't attempt DB queries until DB is confirmed ready

## Files

- `Sources/App/WorldTreeApp.swift` (line 6)
- `Sources/App/AppState.swift` (lines 48-58)
- `Sources/Features/Document/DocumentEditorView.swift` (lines 593, 617-630)
