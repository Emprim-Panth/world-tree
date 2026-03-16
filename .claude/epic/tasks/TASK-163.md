# TASK-163: HIGH — TokenBroadcaster silent sendMessage failure causes ghost message IDs

**Priority**: high
**Status**: Done
**Category**: reliability
**Epic**: Chat Hardening
**Sprint**: 5
**Agent**: geordi
**Complexity**: S

## Description

`TokenBroadcaster.completeTask()` and `TokenBroadcaster.convert(.done)` both use `try?` for `MessageStore.shared.sendMessage()`. When the DB write fails, the fallback is `savedId = UUID().uuidString` — a random ID that doesn't exist in the database.

This ghost ID is broadcast via `WSMessage.messageComplete` to all subscribers. `DocumentEditorView.applyMessages` uses `seenMessageIds` to dedup by the real DB row ID. If the broadcast used a ghost ID but the real message eventually landed in DB (e.g. on retry), the GRDB observation fires with the real ID — which isn't in `seenMessageIds` — causing a duplicate message row in the UI.

Worse: if the DB write truly fails, the message is visible in the UI (from the stream) but gone on restart. Silent data loss.

## Files to Modify

- **Modify**: `Sources/Core/Server/TokenBroadcaster.swift` (lines ~129, ~204)

## Requirements

- Replace `try?` with `do/catch` and log the error at `wtLog("[TokenBroadcaster] ...")` level
- On DB write failure, retry once before falling back to ghost ID
- If ghost ID is used, mark the WSMessage with a `persisted: false` flag so subscribers know the message isn't in DB yet
- Add a note to `completeTask` that ghost IDs should trigger a re-fetch from DB on the subscriber side

## Acceptance Criteria

- [ ] DB write errors in TokenBroadcaster are logged, not silently swallowed
- [ ] Ghost IDs are identifiable by subscribers
- [ ] No silent data loss on transient DB write failures
