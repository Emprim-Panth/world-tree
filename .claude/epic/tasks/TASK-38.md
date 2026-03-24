---
id: TASK-38
title: Simple asciinema replay player in Swift
status: done
priority: low
epic: EPIC-WT-AGENT-WORKSPACE
phase: 4
---

Parse asciinema v2 .cast format (JSON header + JSONL events). Events are [timestamp, "o", text]. Build a simple Swift player: TimedTextPlayer that replays events at their timestamps into a ScrollView. Play/pause/scrub controls. No full terminal emulator needed — just render the output text with monospaced font. Used in ProofDetailView.
