---
id: TASK-25
title: Wire asciinema recording into cortana-dispatch
status: done
priority: high
epic: EPIC-WT-AGENT-WORKSPACE
phase: 1
---

Wrap the `claude --dangerously-skip-permissions` invocation in cortana-dispatch with `asciinema rec`. Store recording at `~/.cortana/recordings/{session_id}.cast`. Check asciinema is installed (brew install if missing). Pass session_id through to filename.
