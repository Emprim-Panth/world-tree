### TASK-46: Delete dead code (NotificationManager, WakeLock, SessionStateStore)
**Epic:** Architecture
**Why:** 301 lines of code that's defined but never called. Violates anti-duplication rule. NotificationManager (71 LOC), WakeLock (71 LOC), SessionStateStore (159 LOC).
**Fix:** Delete the 3 files, regenerate xcodeproj.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** open
