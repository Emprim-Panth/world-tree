# TASK-104: Rate limiting bypass behind proxy

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: X-Forwarded-For trusted only from loopback IPs
**Category**: security
**Source**: QA Audit Wave 2

## Description
AuthRateLimiter.swift trusts X-Forwarded-For header without validation. An attacker behind a proxy can spoof the header to bypass rate limits entirely.

## Acceptance Criteria
- [ ] Validate X-Forwarded-For against allowlist of trusted proxies
- [ ] Fall back to socket address if header is untrusted
- [ ] Add tests for spoofed header scenarios
