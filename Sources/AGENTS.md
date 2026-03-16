# WorldTree Sources Guide

This subtree is the SwiftUI macOS/iOS app and its core runtime.

- Keep product terminology aligned with Starfleet and World Tree, not Pantheon.
- Prefer changes that preserve local-first behavior, SQLite-backed state, and provider isolation.
- Touch `Sources/Core/Providers` carefully: provider routing, stream parsing, and dispatch behavior can break multiple engines at once.
- When changing app state or conversation flow, verify the affected Swift targets build cleanly before stopping.
