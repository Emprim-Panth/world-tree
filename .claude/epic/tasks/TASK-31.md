---
id: TASK-31
title: iMessage delivery of proof package on dispatch complete
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 3
---

On SessionEnd in a dispatch session: call packageProof(), then send iMessage to Evan containing: task name, build status emoji (✅/❌), agent summary (1-2 sentences), up to 3 screenshots attached. Use existing osascript iMessage pipeline. Fire regardless of success/failure so Evan always knows when a dispatch finishes.
