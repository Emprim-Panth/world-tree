# TASK-147: cortana-core Hook — File Touch Tracking

**Priority**: high
**Status**: Todo
**Category**: backend
**Epic**: Agent Orchestration Dashboard
**Sprint**: 2
**Agent**: scotty
**Complexity**: M
**Dependencies**: TASK-134, TASK-138

## Description

Extend cortana-core PostToolUse hook to write `agent_file_touches` rows whenever an agent edits, creates, or deletes a file. This data feeds the conflict detector.

## Files to Modify

- **Modify**: `/Users/evanprimeau/Development/cortana-core/bin/cortana-hooks.ts` — PostToolUse handler

## File Touch Detection

Parse the tool use event to extract file paths:

| Tool | Action | File Path Source |
|------|--------|-----------------|
| `Edit` / `file_edit` | edit | `file_path` parameter |
| `Write` / `file_write` | create/edit | `file_path` parameter |
| `Bash` | varies | Parse command for common patterns: `mv`, `rm`, `cp`, `touch`, redirects (`>`, `>>`) |
| `Read` | read | `file_path` parameter (track reads too for conflict context) |

### Bash Command Parsing (best-effort)

Extract file paths from common bash patterns:
- `rm file.txt` → action=delete, file=file.txt
- `mv old.txt new.txt` → action=delete old.txt, action=create new.txt
- `echo "x" > file.txt` → action=edit, file=file.txt
- `sed -i 's/foo/bar/' file.txt` → action=edit, file=file.txt

Don't try to parse complex pipelines. Best-effort is fine — the Edit/Write tools capture the important cases.

### Deduplication

Don't insert if the same (session_id, file_path, action) was inserted within the last 30 seconds. Prevents rapid edits from flooding the table.

### Cleanup

On SessionEnd, delete file touches older than 48 hours to prevent unbounded growth.

## Acceptance Criteria

- [ ] Edit tool writes file touch with action='edit'
- [ ] Write tool writes file touch with action='create' or 'edit'
- [ ] Bash tool extracts file paths for rm, mv, redirect operations
- [ ] Read tool writes file touch with action='read'
- [ ] Deduplication prevents duplicate inserts within 30s window
- [ ] Old touches cleaned up on session end
- [ ] Agent name and project populated from session context
