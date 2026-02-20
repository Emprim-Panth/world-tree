# Canvas Conversation: Test Branch Check & Conversation Persistence
**Date:** 2025-02-12  
**Branch:** main  
**Status:** Resolved

## Summary
Evan asked to check the status of "this text chain" and the "Test branch in Canvas." This led to discovering that Canvas conversations aren't persisted anywhere, and establishing a system to fix that.

## Key Findings
1. Canvas conversations are **not stored in git** — they're app-level runtime state only
2. CortanaCanvas project exists at `~/Development/CortanaCanvas/`
3. Only one git branch exists: `main` (no "Test" branch in git)
4. "Test branch" in Canvas is an app UI concept, not a git branch
5. **Critical gap:** Important conversations were being lost when sessions ended

## Decisions Made
- Established `/CONVERSATIONS` directory in CortanaCanvas project
- Created convention for exporting significant Canvas threads to markdown
- Defined naming convention: `YYYY-MM-DD-brief-description.md`
- Created README.md documenting the system and when to use it

## Action Items
- [x] Create /CONVERSATIONS directory
- [x] Write README.md with conventions
- [x] Export this conversation as the first example
- [ ] Commit these files to git
- [ ] Reference this system in project documentation if needed

## Conversation Flow

**Evan:** "are you still locked in?"  
**Cortana:** Confirmed operational status.

**Evan:** "Look at this text chain and check into the status"  
**Cortana:** Searched for file references, couldn't find what he meant.

**Evan:** "Literally this conversation, Test branch in Canvas"  
**Cortana:** Attempted to find git branch "Test", discovered Canvas doesn't persist conversations to disk.

**Evan:** "Find where this text chain is located, we need a way to reference it"  
**Cortana:** Searched app containers, found CortanaCanvas project, explained the limitation.

**Evan:** "Please do this"  
**Cortana:** Created this conversation persistence system.

## Technical Notes
- Canvas app data stored in: `~/Library/Containers/com.forgeandcode.cortana-voice/`
- Only preference data found (window positions), no conversation database
- Conversations must be manually exported until Canvas implements export functionality

---

**Participants:** Evan, Cortana  
**Project:** CortanaCanvas  
**Location:** `~/Development/CortanaCanvas/`  
**Outcome:** Established conversation persistence system
