---
id: TASK-35
title: AgentLabView — Live tab
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 4
---

Create `Sources/Features/AgentLab/AgentLabView.swift`. Live tab: polls GET /agent/active every 5s. Shows current session project + task + elapsed time. Polls GET /agent/session/:id/screenshot/latest every 10s and displays the screenshot. Shows a scrolling tail of the terminal recording (read .cast file, display last N lines of output). Auto-refreshes.
