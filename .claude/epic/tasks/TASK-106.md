# TASK-106: Bash tool injection bypass vectors

**Priority**: medium
**Status**: Done
**Completed**: 2026-03-11
**Resolution**: Process substitution <(/>( detection, dangerous ${} parameter expansion detection
**Category**: security
**Source**: QA Audit Wave 2

## Description
ToolGuard misses process substitution (`<(...)`, `>(...)`) and parameter expansion (`${var:-cmd}`) as injection vectors. Attackers can bypass command validation through these bash features.

## Acceptance Criteria
- [ ] Detect process substitution patterns in command validation
- [ ] Detect dangerous parameter expansion patterns
- [ ] Add test cases for each bypass vector
