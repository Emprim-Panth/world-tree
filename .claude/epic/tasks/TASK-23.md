# TASK-23: Update launchd plist and entitlements

**Status:** open
**Priority:** medium
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 4 — Integration
**Depends on:** TASK-22

## Context

World Tree's launchd plist (com.forgeandcode.world-tree) and Xcode entitlements may reference capabilities that are no longer needed (TCC, screen recording) and are missing a new one (network server for port 4863). This task cleans them up.

## Entitlements — WorldTree.entitlements

### Remove (no longer needed)
```xml
<!-- Remove if present — screen recording was for Peekaboo, now gone -->
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
```

### Verify Present
```xml
<!-- Needed for ContextServer HTTP on port 4863 -->
<key>com.apple.security.network.server</key>
<true/>

<!-- Needed for gateway HTTP calls -->
<key>com.apple.security.network.client</key>
<true/>
```

### Verify NOT Present (would cause TCC prompt on launch)
- `com.apple.security.device.microphone` (voice gone)
- Any screen capture entitlement (Peekaboo gone)

## launchd plist — com.forgeandcode.world-tree.plist

Location: `~/Library/LaunchAgents/com.forgeandcode.world-tree.plist`

### Verify KeepAlive is correct
```xml
<key>KeepAlive</key>
<true/>
<key>ThrottleInterval</key>
<integer>5</integer>
```

### Verify RunAtLoad
```xml
<key>RunAtLoad</key>
<true/>
```

### No changes needed to process path or arguments (simplified app still launches the same binary)

## After Editing

```bash
# Reload the launchd plist
launchctl unload ~/Library/LaunchAgents/com.forgeandcode.world-tree.plist
launchctl load ~/Library/LaunchAgents/com.forgeandcode.world-tree.plist

# Verify running
launchctl list | grep world-tree
```

## Acceptance Criteria

- [ ] Read WorldTree.entitlements before editing
- [ ] Screen capture / microphone entitlements removed (if present)
- [ ] Network server + client entitlements present
- [ ] launchd plist KeepAlive and RunAtLoad verified
- [ ] App restarts cleanly via launchd after plist reload
- [ ] App runs for 30+ minutes without crash after full EPIC completion

## Notes

If the entitlements file doesn't have screen capture entitlements, no change is needed — just verify and confirm. Do not add or change entitlements unnecessarily.

This is the final task. After TASK-23, EPIC-WT-SIMPLIFY is complete.
