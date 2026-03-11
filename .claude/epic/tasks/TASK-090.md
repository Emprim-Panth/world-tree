# TASK-090: CRITICAL — File path traversal in glob/grep/read tools

**Status:** Done
**Completed:** 2026-03-11
**Resolution:** Path canonicalization via URL.standardized, null byte rejection, boundary checks for HOME/tmp/var
**Priority:** critical
**Assignee:** —
**Phase:** Security
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

`ToolExecutor.resolvePath()` (line 1151) accepts absolute paths without validation and follows symlinks without detection. The glob, grep, and read_file tools can access any file on the filesystem.

### Current behavior
```swift
private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }  // No boundary check
    if path.hasPrefix("~") { return path.replacingOccurrences(of: "~", with: home) }
    return workingDirectory.appendingPathComponent(path).path
}
```

### Attack vectors
- `globFiles(path: "/etc")` → lists all files in /etc
- `readFile(path: "/Users/evan/.ssh/id_rsa")` → reads SSH keys
- `../../../` sequences escape working directory
- Symlinks followed without detection

## Acceptance Criteria

- [ ] `resolvePath()` canonicalizes paths via `URL.resolvingSymlinksInPath()`
- [ ] All resolved paths validated against working directory boundary
- [ ] Absolute paths rejected unless in explicit allowlist
- [ ] Symlink targets validated against boundary
- [ ] Test with: `readFile(path: "../../../../etc/passwd")`

## Files

- `Sources/Core/Claude/ToolExecutor.swift` (lines 456-514, 1151-1159)
