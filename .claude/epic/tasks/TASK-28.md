---
id: TASK-28
title: Feed screenshot path back to agent via §screenshot signal
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 2
---

After capturing post-build screenshot, output `§screenshot|{path}|{timestamp}` to stdout so it appears in the agent's context. Agent can then read the screenshot, evaluate the UI, and decide whether to iterate. Also POST screenshot metadata to ContextServer `/agent/session/:id/screenshot`.
