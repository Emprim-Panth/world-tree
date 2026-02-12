# Canvas Conversations

This directory tracks significant Canvas conversation threads for the CortanaCanvas project.

## Why This Exists

Canvas conversations are ephemeral — they exist only in app memory and aren't persisted to git. This creates a gap: important decisions, context, and explorations get lost when the session ends.

This directory solves that.

## Convention

When a Canvas conversation contains:
- **Architectural decisions**
- **Implementation plans**
- **Debugging sessions with learnings**
- **Scope changes or clarifications**
- **Anything Evan says "we need to reference this"**

→ Export it to a markdown file here.

## Naming Convention

```
YYYY-MM-DD-brief-description.md
```

Examples:
- `2025-02-12-test-branch-check.md`
- `2025-02-13-authentication-architecture.md`
- `2025-02-15-ui-redesign-discussion.md`

## File Structure

Each conversation log should include:

```markdown
# Canvas Conversation: [Title]
**Date:** YYYY-MM-DD
**Branch:** [git branch if applicable]
**Status:** [Active/Resolved/Archived]

## Summary
[Brief overview of what was discussed]

## Key Decisions
- Decision 1
- Decision 2

## Action Items
- [ ] Task 1
- [ ] Task 2

## Context / Background
[Any relevant context that might be needed later]

---

**Participants:** [Who was involved]
**Project:** CortanaCanvas
**Location:** ~/Development/CortanaCanvas/
```

## Integration with Git

- Commit conversation logs when they represent completed work or decisions
- Reference them in commit messages when relevant
- Link to them from ARCHITECTURE.md or MISSION.md for major decisions

## Automated Export (Future)

Ideally, Canvas would have an export function. Until then, Cortana manually creates these when prompted or when it's clearly valuable.

---

**Established:** 2025-02-12  
**By:** Cortana, First Officer
