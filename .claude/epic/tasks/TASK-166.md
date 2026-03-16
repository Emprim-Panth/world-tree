# TASK-166: Session resume fails after long gap (>15 min idle)

**Status:** Done
**Priority:** high
**Component:** Document / Session Management

## Problem

`isSessionStale` is computed from `lastSendTimestamp`. If the user comes back to a branch after >15 minutes idle, the provider gets `isSessionStale: true` and should re-inject checkpoint context. But `checkpointContext` is only set on rotation — if the session hasn't rotated (short conversation), the stale re-join sends no context at all, and Cortana loses the thread.

## Reproduce

1. Open a branch, send a message, wait 15+ minutes.
2. Send another message.
3. Cortana responds without any prior context ("who are you?" type response).

## Fix

In `processUserInput`, when `isSessionStale == true` and `checkpointContext == nil`, fall back to injecting the last N turns from `document.sections` as context rather than sending bare.

## Acceptance

Sending after 15+ min gap preserves conversation context.
