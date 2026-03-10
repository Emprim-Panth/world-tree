# TASK-083: Filesystem watcher for .pen files — auto re-import on change

**Status:** Done
**Priority:** high
**Assignee:** Geordi
**Phase:** 4 — Visual Verification
**Epic:** EPIC-007 Pencil.dev Intelligence Layer
**Created:** 2026-03-10
**Updated:** 2026-03-10

---

## Description

Add a filesystem watcher to `PencilConnectionStore` that monitors all imported `.pen` file paths for changes. When a change is detected, automatically re-parse and update `pen_assets` + `pen_frame_links` in the database.

**Implementation:**

Add a `DispatchSourceFileSystemObject` watcher (or `FSEvents` via `FSEventStreamCreate`) to `PencilConnectionStore`. On init, install watchers for each `file_path` in `pen_assets`. When a watcher fires:

1. Re-read the `.pen` JSON from disk
2. Re-parse into `PencilDocument` via `PencilModels`
3. Update `pen_assets` row: `frame_count`, `node_count`, `last_parsed`
4. Diff old `pen_frame_links` vs new — delete removed, insert added, update changed
5. Post `Notification(.pencilAssetUpdated, object: penAssetId)` so `PencilDesignSection` refreshes

**Watcher lifecycle:**

- Install watchers in `func startWatching()` — called from `PencilConnectionStore.init`
- Add watcher for each path on new import (`func addWatcher(for path: String)`)
- Cancel all on `deinit` / feature toggle off

**Error handling:**

If the file is unreadable or unparseable, set `lastError` on `PencilConnectionStore` and skip the update. Don't crash.

---

## Acceptance Criteria

- [ ] Modifying a `.pen` file on disk causes World Tree to re-import within 2 seconds
- [ ] `PencilDesignSection` frame list refreshes automatically after watcher fires
- [ ] Newly added frames with annotations get ticket links without manual import
- [ ] Removed frames clear their `pen_frame_links` rows
- [ ] Watcher does not fire on unrelated file changes
- [ ] Feature toggle off (`pencil.feature.enabled = false`) stops all watchers

---

## Notes

- Use `DispatchSource.makeFileSystemObjectSource` with `.write` + `.rename` mask — simpler than FSEvents for individual files
- `.pen` files are JSON — re-parse is cheap
- Watch the file's *directory* with FSEvents if individual fd watchers prove unreliable across editors that write via temp rename
