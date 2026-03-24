# TASK-20: Build ContextServer (HTTP API for session context pull)

**Status:** open
**Priority:** critical
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 3 — New Features
**Depends on:** TASK-18

## Context

ContextServer is the HTTP server running inside World Tree that Claude sessions query to get project context. This is the core of the anti-compaction architecture — sessions pull compressed context instead of carrying it in the context window.

Runs on `127.0.0.1:4863`. Auth token shared with gateway.

## Files to Create

```
Sources/Core/ContextServer/ContextServer.swift
Sources/Core/ContextServer/ContextRoutes.swift
Sources/Core/Models/ProjectBrief.swift
```

## API Contracts

### GET /context/:project
```
Response 200:
{
  "project": "BookBuddy",
  "phase": "Development",
  "milestone": "EPUB parser stability",
  "brain_excerpt": "...",          // first 800 tokens of BRAIN.md
  "open_tickets": [                // up to 10 open tickets, title only
    "TASK-12: Fix EPUB chapter detection",
    ...
  ],
  "recent_dispatches": [           // last 5 dispatches
    { "model": "claude-sonnet-4-6", "status": "completed", "summary": "..." }
  ],
  "blockers": []                   // tickets with priority=critical
}

Response 404: { "error": "Project not found" }
```

### POST /brain/:project/update
```
Request: { "section": "Recently Fixed", "content": "..." }
Response 200: { "ok": true }
Response 400: { "error": "section required" }
// Appends the content under a ## {section} heading in BRAIN.md
// Creates the section if it doesn't exist
```

### POST /session/summary
```
Request: {
  "project": "BookBuddy",
  "summary": "Fixed EPUB chapter detection bug",
  "decisions": ["Use UTF-8 normalization before parsing"],
  "corrections": []
}
Response 200: { "ok": true }
// Appends to BRAIN.md under "## Recent Sessions" section
// Format: ### {timestamp} — {summary}\n**Decisions:** ...\n**Corrections:** ...
```

### GET /health
```
Response 200: { "status": "ok", "uptime": 3600 }
```

## Auth

All endpoints except `/health` require header: `x-cortana-token: {token}`
Token loaded from `~/.cortana/ark-gateway.toml` key `auth_token`.
Return 401 if missing or wrong.

## Port

4863. Make configurable via UserDefaults key `contextServerPort` with default 4863.

## Implementation Notes

Use `Network.framework` (NWListener) or a simple `URLSession`-based HTTP server. Avoid pulling in third-party HTTP server libraries — the surface is small enough to implement with raw socket handling or `HTTPServer` from Foundation (macOS 14+).

ContextServer starts in `WorldTreeApp` on launch (`.task { await ContextServer.shared.start() }`), stops on quit.

Brain excerpt: first 800 tokens ≈ first 3200 characters (rough 4:1 ratio). Just `content.prefix(3200)`.

## Acceptance Criteria

- [ ] Server starts on port 4863 at app launch
- [ ] `GET /context/BookBuddy` returns valid JSON with all fields
- [ ] `POST /brain/BookBuddy/update` appends section to BRAIN.md correctly
- [ ] `POST /session/summary` appends to "Recent Sessions" section
- [ ] Auth rejection (401) for missing/wrong token
- [ ] 404 for unknown project
- [ ] Server stops cleanly on app quit (no port leak)
- [ ] Test with `curl -H "x-cortana-token: ..." http://127.0.0.1:4863/context/BookBuddy`

## Notes

ContextServer reads BRAIN.md directly via BrainFileStore.shared. It does not cache — every request reads fresh from disk. Disk reads for 8 BRAIN.md files are fast enough (~1ms each).
