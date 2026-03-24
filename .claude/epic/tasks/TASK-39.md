---
id: TASK-39
title: Wire Agent Lab into ContentView navigation
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 4
---

Add `.agentLab` to NavigationPanel enum. Add sidebar item: Label("Agent Lab", systemImage: "theatermasks.fill"). Wire to AgentLabView() in detailPanel switch. Add dot badge on sidebar item when a session is active (poll /agent/active).
