### TASK-55: Add data retention policies
**Epic:** Database
**Why:** signal_log at 56K rows, canvas_dispatches at 1.8K, ticket_cache at 2.9K — all growing without bounds. No cleanup, no VACUUM.
**Fix:** Add retention sweep: keep 30 days of signal_log, 90 days of dispatches, 14 days of inference_log. Schedule via dream agent or cron.

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
