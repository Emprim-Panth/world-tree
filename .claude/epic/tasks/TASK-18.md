# TASK-18: Build BrainHost (filesystem BRAIN.md reader/writer)

**Status:** done
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 3 — New Features
**Depends on:** TASK-17

## Context

BrainHost is the Core module that owns BRAIN.md file operations. It discovers all projects under `~/Development/`, reads and writes their `{project}/.claude/BRAIN.md` files, and watches for external changes.

## File to Create

`Sources/Core/BrainHost/BrainFileStore.swift`

## Interface

```swift
actor BrainFileStore {
    static let shared = BrainFileStore()
    private let developmentRoot = URL.homeDirectory.appending(path: "Development")

    /// Returns all project names that have a .claude/BRAIN.md file
    func allProjects() async -> [String]

    /// Read BRAIN.md content for a project. Returns nil if not found.
    func read(project: String) async -> String?

    /// Write content to BRAIN.md. Atomic (write to .brain.tmp, then rename).
    func write(project: String, content: String) async throws

    /// Returns the file URL for a project's BRAIN.md
    func brainURL(for project: String) -> URL

    /// Watch a BRAIN.md for external changes. Fires onChange on the main actor.
    /// Call cancel() on returned handle to stop watching.
    func watch(project: String, onChange: @escaping @MainActor () -> Void) -> WatchHandle
}

final class WatchHandle {
    func cancel()
}
```

## Implementation Notes

- `allProjects()`: `FileManager.default.contentsOfDirectory(at: developmentRoot)`, filter for dirs containing `.claude/BRAIN.md`
- Atomic write: write to `{project}/.claude/.brain.tmp`, then `FileManager.default.moveItem(at: tmp, to: brain)` — moveItem is atomic on same volume
- Watch: `DispatchSource.makeFileSystemObjectSource(fileDescriptor:, eventMask: .write)` on the directory containing BRAIN.md
- Never crash if BRAIN.md doesn't exist — return nil from read, create it on first write

## Acceptance Criteria

- [ ] `allProjects()` returns correct list from ~/Development/
- [ ] `read()` returns nil for missing projects, string content for existing ones
- [ ] `write()` uses atomic rename pattern — no in-place overwrite
- [ ] `watch()` fires within 2 seconds of an external edit
- [ ] No crash if BRAIN.md doesn't exist for a project
- [ ] File compiles and integrates with BrainEditorView in TASK-19

## Notes

This is a pure filesystem actor — no database, no network. Keep it simple. The watch mechanism only needs to detect that the file changed, not what changed.
