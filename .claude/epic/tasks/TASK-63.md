### TASK-63: Make Ticket.status a proper enum
**Why:** Raw strings ("pending", "in_progress", etc.) used throughout. Palette.forStatus() already maps them.

### TASK-64: Extract FileWatcher utility
**Why:** DispatchSource file-watching pattern repeated in 4 files.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
