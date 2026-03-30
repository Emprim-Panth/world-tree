### TASK-53: Security hardening — move tokens to Keychain
**Epic:** Agent Ecosystem
**Why:** nerve.toml contains bearer tokens in plaintext. No secret scanning in commits. No cert expiry monitoring.
**Fix:** Move nerve tokens to Keychain. Add pre-commit secret scanning hook. Add cert expiry alert (30-day warning).

**Epic:** EPIC-WT-DEEP-INSPECT
**Status:** done
