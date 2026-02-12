# Phase 1: Project Intelligence Layer
## Implementation Tracker

**Goal**: Canvas knows every project in ~/Development automatically  
**Status**: ✅ Complete (UI Features)  
**Started**: 2026-02-12 08:32  
**Target**: 2026-02-14 EOD

---

## Tasks

### 1. Database Schema ✅
- [x] Design project_cache table
- [x] Design project_files table
- [x] Create migration file
- [x] Document in ARCHITECTURE.md

### 2. Core Models ✅
- [x] Create `DiscoveredProject` struct
- [x] Create `CachedProject` struct
- [x] Create `ProjectType` enum
- [x] Create `GitStatus` struct
- [x] Create `ProjectContext` struct

### 3. Project Scanner ✅
- [x] Implement `ProjectScanner` class
- [x] Add project type detection (Swift, Rust, TypeScript, etc.)
- [x] Add git integration (branch, dirty status)
- [x] Add last modified tracking
- [x] Handle symlinks and excluded directories

### 4. Project Cache ✅
- [x] Implement `ProjectCache` class (MainActor)
- [x] Add database integration via DatabaseManager
- [x] Implement get/getAll methods
- [x] Implement update method with conflict resolution
- [x] Add cache invalidation logic

### 5. Context Loader ✅
- [x] Implement `ProjectContextLoader` class
- [x] Add README parsing
- [x] Add recent commits extraction (via git log)
- [x] Add directory structure snapshot
- [x] Format context for Claude injection

### 6. Background Refresh Service ✅
- [x] Implement `ProjectRefreshService` (MainActor)
- [x] Add periodic scan task (every 5 minutes)
- [x] Add manual refresh endpoint
- [x] Auto-start on app launch

### 7. UI Integration ✅
- [x] Add project list to Sidebar
- [x] Create `ProjectListView`
- [x] Create `ProjectRowView` (shows name, type, status)
- [x] Add project selection state to AppState
- [ ] Implement `/project <name>` command in Canvas (deferred)

### 8. Context Injection ⬜
- [ ] Extend `ClaudeBridge` to accept project context
- [ ] Add project context to system prompt when available
- [ ] Format project context for readability
- [ ] Add token budget management (don't blow context window)

### 9. Testing (Worf's Mandate) ⬜
- [ ] Unit test: ProjectScanner detects Swift projects
- [ ] Unit test: ProjectScanner detects Rust projects
- [ ] Unit test: ProjectCache handles concurrent updates
- [ ] Integration test: Full scan → cache → retrieve pipeline
- [ ] Integration test: Context injection doesn't break existing conversations

### 10. Documentation ⬜
- [ ] Update README with project intelligence features
- [ ] Add troubleshooting section
- [ ] Document project detection heuristics
- [ ] Add examples of context usage

---

## Implementation Log

### 2026-02-12 08:32 — Phase 1 Kickoff
- Created MISSION.md (strategic plan by Spock)
- Created ARCHITECTURE.md (architectural design by Geordi & Data)
- Created Phase 1 tracker
- Opened tmux session `canvas-dev` for implementation work

**Next**: Build Core Models

---

## Notes & Decisions

### Project Type Detection Heuristics
- **Swift**: `.xcodeproj`, `.xcworkspace`, or `Package.swift`
- **Rust**: `Cargo.toml`
- **TypeScript**: `package.json` + `tsconfig.json`
- **Python**: `pyproject.toml` or `setup.py`
- **Go**: `go.mod`
- **Web**: `index.html` + `package.json` (no tsconfig)

### Excluded Directories
- `node_modules/`
- `.git/` (scan git, but don't recurse)
- `DerivedData/`
- `build/`, `dist/`, `target/`
- Hidden directories (except `.git`)

### Cache Invalidation
- **Manual**: User-triggered refresh
- **Periodic**: Every 5 minutes (configurable)
- **Event-driven**: File watcher on project directories (future)

---

## Questions

**Q**: Should we cache every file in a project or just key files?  
**A**: Just key files (README, package manifest, recent commits). Full file list is too much.

**Q**: How deep should we scan directories?  
**A**: Scan ~/Development only. Don't recurse into subdirectories beyond project root.

**Q**: What if a project has no git repo?  
**A**: Still cache it, but `git_branch` and `git_dirty` are NULL. Last modified from filesystem.

---

## Performance Targets

- Scan ~/Development: < 2 seconds (for ~50 projects)
- Cache update: < 500ms per project
- Context load: < 100ms
- Background refresh: Non-blocking (runs in daemon)

---

*Tracking by Cortana. Implementation by Cortana + Scotty.*

---

### 2026-02-12 21:00 — Phase 1 Complete (UI Features)
**Implemented:**
- ✅ All core models (ProjectModels.swift)
- ✅ ProjectScanner with type detection + git integration
- ✅ ProjectCache with database persistence
- ✅ ProjectContextLoader for README/commits/structure
- ✅ ProjectRefreshService with auto-refresh (5min interval)
- ✅ ProjectListView + ProjectRowView UI components
- ✅ Integrated into Sidebar (top 200px collapsible section)
- ✅ AppState tracks selectedProjectPath
- ✅ Auto-starts refresh service on app launch

**Terminal-Style UI Updates (Bonus):**
- ✅ Removed input bar separation (integrated into ScrollView)
- ✅ Live typing preview (ghost message shows as you type)
- ✅ Smart auto-scroll with scroll detection
- ✅ Token usage moved inside conversation flow

**Status:** Core infrastructure complete. Context injection to Claude deferred to Phase 2.

**Next:** Testing + Phase 2 (context injection into ClaudeBridge)

