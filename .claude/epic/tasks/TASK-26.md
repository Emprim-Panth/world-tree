---
id: TASK-26
title: Store recordings, add 14-day prune cron
status: done
priority: medium
epic: EPIC-WT-AGENT-WORKSPACE
phase: 1
---

Ensure `~/.cortana/recordings/` directory exists. Add a cron/launchd job that prunes `.cast` files older than 14 days. Update cortana-heartbeat maintenance cycle to include recording cleanup.
