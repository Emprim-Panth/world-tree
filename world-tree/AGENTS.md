# WorldTree CLI Guide

This subtree is for the local `world-tree` helper surface.

- Keep commands predictable and script-friendly.
- Prefer explicit flags, stable output, and clear failure messages over clever behavior.
- If a command bridges into app state, database state, or MCP tooling, preserve backward-compatible behavior unless the repo intentionally changes the contract.
- Add deeper `AGENTS.md` files only if this subtree grows distinct command groups.
