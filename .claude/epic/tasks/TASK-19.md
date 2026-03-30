# TASK-19: Build BrainEditorView (native SwiftUI BRAIN.md editor)

**Status:** done
**Priority:** high
**Epic:** EPIC-WT-SIMPLIFY
**Phase:** 3 — New Features
**Depends on:** TASK-18

## Context

BrainEditorView replaces the chat-based Brain views (deleted in TASK-11). It gives Evan a native macOS editor to view and edit BRAIN.md files for any project — replacing terminal-based file editing.

## File to Create

`Sources/Features/Brain/BrainEditorView.swift`

## Spec

```
┌─────────────────────────────────────────────────────────┐
│  Brain Editor                              [Project ▼]  │
├─────────────────────────────┬───────────────────────────┤
│  (raw markdown TextEditor)  │  (rendered preview)       │
│                             │                           │
│  # World Tree — BRAIN.md    │  World Tree — BRAIN.md    │
│                             │                           │
│  ## Current Phase           │  Current Phase            │
│  ...                        │  ...                      │
│                             │                           │
├─────────────────────────────┴───────────────────────────┤
│  Last modified: 2026-03-23 14:32 · 4,821 chars · Saved  │
└─────────────────────────────────────────────────────────┘
```

## Implementation

```swift
struct BrainEditorView: View {
    @State private var selectedProject: String = ""
    @State private var content: String = ""
    @State private var saveStatus: SaveStatus = .saved
    @State private var lastModified: Date?
    @State private var watchHandle: WatchHandle?
    @State private var externalChangeWarning: Bool = false

    private let brainStore = BrainFileStore.shared
    private let saveDebounce = Debouncer(delay: 1.0)

    var body: some View {
        HSplitView {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .onChange(of: content) { scheduleSave() }

            MarkdownPreview(markdown: content)  // WKWebView wrapper
        }
        .toolbar { projectPicker }
        .safeAreaInset(edge: .bottom) { statusBar }
        .task(id: selectedProject) { await loadProject() }
        .alert("File changed externally", isPresented: $externalChangeWarning) {
            Button("Reload") { Task { await loadProject() } }
            Button("Keep mine", role: .cancel) {}
        }
    }
}

enum SaveStatus { case saved, saving, unsaved, error(String) }
```

**MarkdownPreview:** WKWebView that renders the markdown string as HTML. Use a simple CSS reset + monospace font. No need for a full markdown library — basic heading, bold, code block rendering is sufficient.

**Debouncer:** Simple class that delays an action by N seconds, canceling the previous timer on each call. Used for autosave.

## Acceptance Criteria

- [ ] Project picker shows all projects from BrainFileStore.allProjects()
- [ ] Left pane: editable TextEditor with monospace font
- [ ] Right pane: rendered markdown preview (headings, code, lists minimum)
- [ ] Autosave fires 1 second after last keystroke
- [ ] Status bar shows last modified time, character count, save status
- [ ] External change detected → "File changed externally" alert (reload / keep mine)
- [ ] Atomic write used (via BrainFileStore.write)
- [ ] Empty project (no BRAIN.md) shows "No BRAIN.md found. Start typing to create one."

## Notes

Do not add rich text, syntax highlighting, or formatting toolbar. Plain TextEditor is correct — these are engineering notes, not documents.
