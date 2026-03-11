import SwiftUI
import UserNotifications

@main
struct WorldTreeApp: App {
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onContinueUserActivity("com.evanprimeau.worldtree.viewBranch") { activity in
                    guard let treeId = activity.userInfo?["treeId"] as? String,
                          let branchId = activity.userInfo?["branchId"] as? String else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    appState.selectBranch(branchId, in: treeId)
                }
                .onAppear {
                    // Crash sentinel — detect abnormal exits from previous session
                    _ = CrashSentinel.shared.checkAndStart()

                    checkForUpdateBadge()
                    // DB is set up in AppState.init() — just surface any error here
                    if let error = appState.dbSetupError {
                        wtLog("[WorldTree] Database setup failed: \(error)")
                        let alert = NSAlert()
                        alert.messageText = "World Tree — Database Error"
                        alert.informativeText = "Failed to open the conversation database.\n\n\(error.localizedDescription)\n\nCheck that ~/.cortana/claude-memory/ exists, or configure a different database path in Settings."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "Open Settings")
                        alert.addButton(withTitle: "Quit")
                        let response = alert.runModal()
                        if response == .alertSecondButtonReturn {
                            NSApp.terminate(nil)
                        } else {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        }
                    }
                    validateRestoredSelection()
                    startProjectRefresh()
                    Task {
                        do { await PermissionsService.shared.setup() }
                        catch { wtLog("[WorldTree] PermissionsService setup failed: \(error)") }
                    }
                    Task {
                        do { await ProviderManager.shared.refreshHealth() }
                        catch { wtLog("[WorldTree] ProviderManager refresh failed: \(error)") }
                    }
                    Task {
                        do { EventStore.shared.prune() }
                        catch { wtLog("[WorldTree] EventStore prune failed: \(error)") }
                    }
                    DispatchSupervisor.shared.start()
                    DispatchSupervisor.shared.pruneOldDispatches()
                    BranchTerminalManager.shared.recoverOrphanedSessions()
                    // Pre-warm terminals for all recently-active branches that have a persisted
                    // tmux session — instant terminal attach when navigating between branches.
                    // workingDirectory is on the tree; for tmux reattach it's irrelevant
                    // (the session already exists at its own CWD). Pass home as fallback.
                    Task {
                        if let branches = try? DatabaseManager.shared.read({ db in
                            try Branch.fetchAll(db, sql: """
                                SELECT * FROM canvas_branches
                                WHERE tmux_session_name IS NOT NULL
                                  AND updated_at > datetime('now', '-7 days')
                                LIMIT 20
                                """)
                        }) {
                            await MainActor.run {
                                for branch in branches {
                                    BranchTerminalManager.shared.warmUp(
                                        branchId: branch.id,
                                        workingDirectory: NSHomeDirectory(),
                                        knownTmuxSession: branch.tmuxSessionName
                                    )
                                }
                                if !branches.isEmpty {
                                    wtLog("[WorldTree] Pre-warmed \(branches.count) branch terminal(s)")
                                }
                            }
                        }
                    }
                    // Compass + Tickets + Heartbeat: initial scan on launch
                    CompassStore.shared.refresh()
                    TicketStore.shared.scanAll()
                    HeartbeatStore.shared.refresh()
                    if UserDefaults.standard.bool(forKey: AppConstants.daemonChannelEnabledKey) {
                        DaemonService.shared.startMonitoring()
                    }
                    startWorldTreeServerIfEnabled()
                    startPluginServerIfEnabled()
                    if UserDefaults.standard.bool(forKey: "pencil.feature.enabled") {
                        launchPencilInBackground()
                        Task {
                            // Give Pencil a moment to finish launching before polling
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            await PencilConnectionStore.shared.startPolling()
                        }
                    }
                    PeekabooBridgeServer.shared.start()
                    WTCommandBridge.shared.start()
                    GlobalHotKey.shared.register()
                    // VoiceService configures lazily on first use — no startup call needed
                    Task {
                        do {
                            // Recover any responses that were interrupted by a crash or SIGTERM.
                            // Mark those sessions for auto-resume so the document view fires a
                            // continuation prompt automatically — no user input required.
                            let recovered = await StreamCacheManager.shared.recoverOrphanedStreams()
                            for (sessionId, content) in recovered where !content.isEmpty {
                                wtLog("[StreamCache] Recovering interrupted response for session \(sessionId)")
                                let msg = "[Recovered — response was interrupted]\n\n\(content)"
                                _ = try? MessageStore.shared.sendMessage(sessionId: sessionId, role: .assistant, content: msg)
                                await MainActor.run {
                                    DocumentEditorViewModel.pendingAutoResume.insert(sessionId)
                                }
                            }
                        } catch {
                            wtLog("[WorldTree] Stream recovery failed: \(error)")
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        clearUpdateBadge()
                    }
                    if phase == .background {
                        DaemonService.shared.stopMonitoring()
                        CrashSentinel.shared.markCleanExit()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    CrashSentinel.shared.markCleanExit()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tree") {
                    NotificationCenter.default.post(name: .createNewTree, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Branch") {
                    NotificationCenter.default.post(name: .createNewBranch, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Back") { appState.navigateBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!appState.canGoBack)

                Button("Forward") { appState.navigateForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!appState.canGoForward)

                Divider()

                Button("Find in Conversation") {
                    NotificationCenter.default.post(name: .showConversationSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Search Everything") {
                    appState.showGlobalSearch = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            Button("Open World Tree") {
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("New Tree") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .createNewTree, object: nil)
            }
            Button("New Branch") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .createNewBranch, object: nil)
            }
            Divider()
            Button("Quit World Tree") {
                NSApp.terminate(nil)
            }
        } label: {
            Image(systemName: appState.activeTaskCount > 0 ? "tree.circle.fill" : "tree.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    /// Validate that the restored tree/branch still exist in the DB.
    /// Clears the selection if either has been deleted since last session.
    /// Also pre-warms the terminal for the restored branch so it's live when the
    /// user's view appears — no waiting, no black screen, no manual trigger needed.
    private func validateRestoredSelection() {
        guard let treeId = appState.selectedTreeId else { return }
        Task { @MainActor in
            let treeExists = (try? TreeStore.shared.getTree(treeId)) != nil
            if !treeExists {
                appState.selectedTreeId = nil
                appState.selectedBranchId = nil
                return
            }
            // Pre-warm terminal for the restored branch.
            // workingDirectory lives on the tree, tmuxSessionName on the branch.
            if let branchId = appState.selectedBranchId,
               let branch = try? TreeStore.shared.getBranch(branchId),
               let tree = try? TreeStore.shared.getTree(branch.treeId) {
                let workDir = tree.workingDirectory ?? NSHomeDirectory()
                BranchTerminalManager.shared.warmUp(
                    branchId: branchId,
                    workingDirectory: workDir,
                    knownTmuxSession: branch.tmuxSessionName
                )
                wtLog("[WorldTree] Pre-warmed terminal for restored branch \(branchId.prefix(8))")
            }
        }
    }
    
    private func startProjectRefresh() {
        ProjectRefreshService.shared.startAutoRefresh()
    }

    /// Launch Pencil.app in the background — hidden, no activation.
    /// If already running, this is a no-op (NSWorkspace won't open a second instance).
    private func launchPencilInBackground() {
        let candidates = [
            "/Applications/Pencil.app",
            "\(NSHomeDirectory())/Applications/Pencil.app"
        ]
        guard let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            wtLog("[WorldTree] Pencil.app not found — skipping auto-launch")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: appPath),
            configuration: config
        ) { _, error in
            if let error {
                wtLog("[WorldTree] Pencil background launch failed: \(error.localizedDescription)")
            } else {
                wtLog("[WorldTree] Pencil launched in background")
            }
        }
    }

    private func startWorldTreeServerIfEnabled() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: WorldTreeServer.enabledKey) == nil {
            defaults.set(true, forKey: WorldTreeServer.enabledKey) // default on
        }
        guard defaults.bool(forKey: WorldTreeServer.enabledKey) else { return }
        WorldTreeServer.shared.start()
    }

    private func checkForUpdateBadge() {
        let sentinel = URL(fileURLWithPath: "/tmp/.worldtree-updated")
        if FileManager.default.fileExists(atPath: sentinel.path) {
            NSApp.dockTile.badgeLabel = "↑"
        }
    }

    private func clearUpdateBadge() {
        guard NSApp.dockTile.badgeLabel != nil && NSApp.dockTile.badgeLabel != "" else { return }
        NSApp.dockTile.badgeLabel = nil
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/.worldtree-updated"))
    }

    /// Plugin server is enabled by default (daemon-local, loopback only).
    /// Users can disable via Settings → Plugin Server, or set cortana.pluginEnabled = false.
    private func startPluginServerIfEnabled() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: AppConstants.pluginServerEnabledKey) == nil {
            defaults.set(true, forKey: AppConstants.pluginServerEnabledKey) // default on
        }
        guard defaults.bool(forKey: AppConstants.pluginServerEnabledKey) else { return }
        PluginServer.shared.start()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let createNewTree = Notification.Name("createNewTree")
    static let createNewBranch = Notification.Name("createNewBranch")
    static let showConversationSearch = Notification.Name("showConversationSearch")
    static let forkLastMessage = Notification.Name("forkLastMessage")
}
