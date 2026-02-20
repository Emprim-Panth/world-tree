# WorldTree — Design Verification Config

Used by Data (design-forge, design-review) to locate all project-specific resources.

## Project

```yaml
project: worldtree
platform: macos
company: Forge&Code
```

## Build

```yaml
workspace: /Users/evanprimeau/Development/CortanaCanvas/WorldTree.xcodeproj
scheme: WorldTree
bundle-id: com.evanprimeau.cortanacanvas
destination: "platform=macOS"
derived-data: /tmp/forge-dd-worldtree
```

## Capture

```yaml
# macOS projects: use peekaboo for screenshots (not xcrun simctl)
# peekaboo see --app "WorldTree" --path /tmp/review.png
screenshot-method: peekaboo
axe: ~/.cortana/bin/simctl-axe   # tap/interact limited on macOS
peekaboo: /opt/homebrew/bin/peekaboo
```

## Navigation

```yaml
# WorldTree opens to the Dashboard view (conversation tree browser + canvas)
# On macOS, use AppleScript / peekaboo interaction for forge preview navigation
default-landing: Dashboard
```

## Design System

```yaml
# Status: NOT YET ESTABLISHED
# No global token system — colors are hardcoded in individual components.
# Run brand-kit skill first, then design-system to install.
design-tokens: Sources/Shared/DesignSystem/
token-prefix: CC
# Token naming: CCPalette, CCFont, CCSpacing, CCRadius
```

## Current Components

```yaml
components: Sources/Shared/Components/
# Existing: ModelBadge, ProviderBadge, KeyboardHandlingTextEditor,
#           StatusBadge, CodeBlockView, ContextGauge, DiffView
# Hardcoded colors: .mint, .indigo, .orange, .secondary — replace with CC tokens
```

## Platform Notes

```yaml
# macOS design-forge is different from iOS:
# - No simulator — build and run the app directly
# - Screenshots via peekaboo (not simctl)
# - UI interaction via AppleScript or accessibility APIs
# - Navigation via menu bar or keyboard shortcuts
# - Design forge support is iOS-first; macOS is best-effort
```

## Known Issues

- No global design token system yet (brand-kit must run first)
- macOS capture pipeline is less automated than iOS (peekaboo replaces simctl)
- Hardcoded colors throughout existing components — migration needed after tokens established
