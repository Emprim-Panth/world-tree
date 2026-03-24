---
id: TASK-32
title: POST proof package to ContextServer
status: done
priority: medium
epic: EPIC-WT-AGENT-WORKSPACE
phase: 3
---

After assembling proof, POST to `http://127.0.0.1:4863/agent/session/:id/proof`. ContextServer stores in agent_sessions table and notifies World Tree via in-memory update. 3s timeout, fire-and-forget.
