# TASK-096: HIGH — Swallowed errors throughout codebase (try? epidemic)

**Status:** Done
**Priority:** high
**Assignee:** —
**Phase:** Stability
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

Widespread use of `try?` that converts errors to nil/false, making debugging impossible. Key locations:

### Critical paths
1. **validateRestoredSelection()** (ClaudeCodeProvider.swift:215-226) — DB errors treated as "doesn't exist", user loses restored session silently
2. **FTS5 table creation** (MigrationManager.swift:262-268, 417-429) — `try?` on CREATE TABLE; if FTS5 fails, search silently degrades to LIKE
3. **hasMessages()** (MessageStore.swift:17-42) — returns `false` if DB error, not just "no messages"
4. **resolveParentSessionId()** (SendContextBuilder.swift:266-272) — parent session silently null on DB error, losing fork context
5. **warmUp()** (AnthropicAPIProvider.swift:358-376) — context pre-loading errors ignored

### Pattern
All share the same anti-pattern: `try?` where the caller can't distinguish "doesn't exist" from "error reading". This masks database corruption, permissions issues, and query bugs.

## Acceptance Criteria

- [x] Critical paths log errors: `do { ... } catch { wtLog(...) }`
- [x] DB read operations return Result<T, Error> or throw where callers need to distinguish
- [x] FTS5 creation failures logged with specific error
- [x] At minimum: ALL `try?` in database operations logged before discarding

## Files

- `Sources/Core/Providers/ClaudeCodeProvider.swift` (lines 215-226)
- `Sources/Core/Database/MigrationManager.swift` (lines 262-268, 417-451)
- `Sources/Core/Database/MessageStore.swift` (lines 17-42)
- `Sources/Core/Context/SendContextBuilder.swift` (lines 266-272)
- `Sources/Core/Providers/AnthropicAPIProvider.swift` (lines 358-376)
