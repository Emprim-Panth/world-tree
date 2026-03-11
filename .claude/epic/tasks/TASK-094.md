# TASK-094: HIGH — Fix test build: codesign script blocks test execution

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Codesign script guards for ACTION!=build and WRAPPER_EXTENSION=xctest, removed --deep
**Priority:** high
**Assignee:** —
**Phase:** Testing
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

The "Install to /Applications" post-build script uses `codesign --deep` which tries to sign the embedded `.xctest` bundle during test builds, causing failure:

```
/Applications/World Tree.app: bundle format unrecognized, invalid, or unsuitable
In subcomponent: /Applications/World Tree.app/Contents/PlugIns/WorldTreeTests.xctest
```

This blocks ALL test execution from the command line (`xcodebuild test`).

## Acceptance Criteria

- [ ] Tests can run via `xcodebuild -scheme WorldTree test`
- [ ] Install script skips during test actions (check `$ACTION == "test"`)
- [ ] OR remove `--deep` flag and sign only main binary
- [ ] All existing tests pass

## Files

- `project.yml` (postBuildScripts section)
