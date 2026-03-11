# TASK-095: HIGH — Message hasBranches always false (Int vs Int64 GRDB cast bug)

**Status:** Done
**Priority:** high
**Assignee:** —
**Phase:** Bug Fix
**Epic:** QA Audit Wave 2
**Created:** 2026-03-11
**Updated:** 2026-03-11

---

## Description

`Message.init(row:)` uses `row["has_branches"] as? Int` but GRDB returns `Int64`. The cast always returns nil/0, so `hasBranches` is effectively always false.

Documented in `MessageStoreTests` lines 364-367 as a known latent bug.

### Impact
- Branch fork indicators never appear on messages
- Users can't see which messages have forks from the conversation view
- Breaks visual tree navigation

## Acceptance Criteria

- [ ] Fix cast to `Int64` or use GRDB's typed `row[Column("has_branches")] as Int`
- [ ] Branch fork indicators appear correctly on messages that have forks
- [ ] Existing test updated to verify the fix

## Files

- `Sources/Core/Models/Message.swift` (init(row:))
- `Tests/MessageStoreTests/` (lines 364-367)

## Completion

Fixed in cycle 7 — Message.hasBranches reads column as Int64 then converts to Bool. Commit ffc6d45.
