---
id: TASK-34
title: ContextServer routes for agent sessions
status: done
priority: medium
epic: EPIC-WT-AGENT-WORKSPACE
phase: 4
---

Add to ContextServer.swift: GET /agent/active, GET /agent/sessions (last 30), GET /agent/session/:id/proof, POST /agent/session/:id/proof, GET /agent/session/:id/screenshot/latest. All read/write from agent_sessions and agent_screenshots tables via GRDB.
