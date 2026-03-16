# TASK-165: MEDIUM — WorldTreeServer silent sendMessage at line 758

**Priority**: medium
**Status**: Done
**Category**: reliability
**Epic**: Chat Hardening
**Sprint**: 5
**Agent**: geordi
**Complexity**: XS

## Description

`WorldTreeServer.swift` line 758 discards a `sendMessage` result with `_ = try?`. If the DB write fails here, the message is silently dropped — no log, no retry, no caller notification.

This is distinct from the `TokenBroadcaster` issue (TASK-163) because it happens on the server path, not the broadcast path. Affects messages sent via the Unix socket IPC layer.

## Files to Modify

- **Modify**: `Sources/Core/Server/WorldTreeServer.swift` (~line 758)

## Requirements

- Replace `_ = try?` with `do/catch` and log the error
- If this is on a hot path (called per-token), log at `.debug` level to avoid noise

## Acceptance Criteria

- [ ] DB write errors on the server path are logged
- [ ] No silent drops on transient failures
