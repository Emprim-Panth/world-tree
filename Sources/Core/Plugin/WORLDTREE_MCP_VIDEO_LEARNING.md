# World Tree MCP — Video Learning

> Native World Tree MCP wrapper for the legacy `learn-video` workflow.

This is the correct layer for video learning in the current stack.
The old Claude `learn-video` skill was just a wrapper around `~/.cortana/bin/learn-video`.
Codex should call World Tree's MCP server, and World Tree should queue the work as a background job.

## Tools

### `world_tree_learn_video`
Queues the local learner and returns a `job_id`.

Arguments:

```json
{
  "project": "SignalForge",
  "mode": "video",
  "input": "https://youtu.be/Rjd1LqF9cG4",
  "visual": false
}
```

Supported modes:

- `video` — direct URL, transcript-first flow, optional `visual: true`
- `full` — direct URL, transcript + visual
- `visual` — visual-only analysis
- `workflow` — workflow extraction mode
- `search` — search query, optional `max_results`, optional `visual: true`
- `playlist` — playlist URL, optional `max_results`
- `list` — list prior learnings
- `status` — check dependencies / API visibility

Arguments:

- `project`: tracked World Tree project name. Used to resolve the working directory.
- `working_directory`: absolute path override. Takes precedence over `project`.
- `input`: URL or search query depending on mode.
- `visual`: only meaningful for `video` and `search`.
- `max_results`: only meaningful for `search` and `playlist`.

Returns:

```json
{
  "job_id": "UUID",
  "type": "video_learning",
  "project": "SignalForge",
  "working_directory": "/Users/evanprimeau/Development/SignalForge",
  "mode": "video",
  "input": "https://youtu.be/Rjd1LqF9cG4",
  "visual": false,
  "max_results": null,
  "output_path_hint": "/Users/evanprimeau/Development/SignalForge/.claude/knowledge/video-learnings",
  "notes": "Queued in World Tree JobQueue. Poll world_tree_get_job with the returned job_id for status and output."
}
```

### `world_tree_get_job`
Fetches a queued or completed job by ID.

Arguments:

```json
{
  "job_id": "UUID"
}
```

Returns:

```json
{
  "id": "UUID",
  "type": "video_learning",
  "command": "/bin/zsh -lc '...'",
  "working_directory": "/Users/evanprimeau/Development/SignalForge",
  "branch_id": null,
  "status": "completed",
  "created_at": "2026-03-13T12:00:00Z",
  "completed_at": "2026-03-13T12:04:12Z",
  "output": "...",
  "output_truncated": false,
  "error": null
}
```

## Operational Notes

- Work is queued through `JobQueue`, not run inline on the MCP request thread.
- The command is launched through `zsh -lc` so it behaves more like the legacy terminal workflow.
- Outputs are still written by the learner itself under:

```text
<project>/.claude/knowledge/video-learnings/
```

- `visual` mode still depends on `GOOGLE_API_KEY` or `GEMINI_API_KEY` being available to World Tree's process environment.
- Transcript-only modes can still provide value even when visual mode is unavailable.
