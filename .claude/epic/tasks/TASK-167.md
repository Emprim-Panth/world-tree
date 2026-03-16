# TASK-167: autoResumeIfNeeded fires on every branch load with unanswered turn

**Status:** open
**Priority:** medium
**Component:** Document / Auto-Resume

## Problem

`autoResumeIfNeeded` checks if the last DB message is from the user with no assistant reply, and if `hasCheckpointContext || messageCount > 1`, it auto-submits. This fires correctly after a crash. But it also fires when you deliberately switch away mid-conversation and come back — even if you intentionally left without sending.

The `messageCount > 1` condition means any branch with more than one message and a trailing user message will auto-re-submit on every load. Users who draft a message, navigate away, and come back find it was sent without their confirmation.

## Fix

Add a `userAbortedAt` timestamp to `canvas_branches`. If the last user message was present before a voluntary navigation away (not a crash), mark it so `autoResumeIfNeeded` skips it.

Simpler alternative: only auto-resume if the app was previously in `isProcessing = true` state (i.e., the stream was actively running when we left, not just a draft sitting there).

## Acceptance

Auto-resume fires after crash/interrupted stream but NOT after voluntary navigation away.
