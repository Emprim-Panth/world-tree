# TASK-14: Rebuild project.yml (remove SwiftTerm, clean sources)

**Status:** done
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 2 — Build Stabilize
**Depends on:** TASK-13

## Context

project.yml declares all source paths, dependencies, and build settings. After Phase 1 deletions, it references non-existent files and includes SwiftTerm (terminal emulator dependency) which is no longer needed. This task gets the project building cleanly.

## Required Changes

### Remove dependency
```yaml
# DELETE this entire block:
SwiftTerm:
  url: https://github.com/migueldeicaza/SwiftTerm.git
  from: 1.2.0
```

### Update sources
project.yml likely uses wildcard `sources: [path: Sources]`. If so, deleted files are already gone and no explicit update is needed. If it uses explicit file lists, remove all references to deleted files.

### Update target dependencies
Remove `SwiftTerm` from the WorldTree target's `dependencies` list.

### Verify
After editing project.yml:
```bash
xcodegen
# Should complete without errors
```

## Acceptance Criteria

- [ ] SwiftTerm removed from packages
- [ ] SwiftTerm removed from target dependencies
- [ ] `xcodegen` completes without errors
- [ ] `xcodebuild -scheme WorldTree -dry-run` lists only files that exist on disk

## Notes

Do NOT run a full build yet — there are still broken import references in the kept files (AppState, ContentView, CommandCenterView, etc.) that get fixed in TASK-15/16/17. The goal of this task is only: xcodegen succeeds and the project file reflects reality.
