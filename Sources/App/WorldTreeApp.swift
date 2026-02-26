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
                .onAppear {
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
                    Task { await PermissionsService.shared.setup() }
                    Task { await ProviderManager.shared.refreshHealth() }
                    Task { EventStore.shared.prune() }
                    DispatchSupervisor.shared.start()
                    DispatchSupervisor.shared.pruneOldDispatches()
                    BranchTerminalManager.shared.recoverOrphanedSessions()
                    startWorldTreeServerIfEnabled()
                    startPluginServerIfEnabled()
                    PeekabooBridgeServer.shared.start()
                    WTCommandBridge.shared.start()
                    GlobalHotKey.shared.register()
                    // VoiceService configures lazily on first use — no startup call needed
                    Task {
                        // Recover any responses that were interrupted by a crash or SIGTERM
                        let recovered = await StreamCacheManager.shared.recoverOrphanedStreams()
                        for (sessionId, content) in recovered where !content.isEmpty {
                            wtLog("[StreamCache] Recovering interrupted response for session \(sessionId)")
                            let msg = "[Recovered — response was interrupted]\n\n\(content)"
                            _ = try? MessageStore.shared.sendMessage(sessionId: sessionId, role: .assistant, content: msg)
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        clearUpdateBadge()
                    }
                    if phase == .background {
                        DaemonService.shared.stopMonitoring()
                    }
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
            Image(systemName: "tree.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    /// Validate that the restored tree/branch still exist in the DB.
    /// Clears the selection if either has been deleted since last session.
    private func validateRestoredSelection() {
        guard let treeId = appState.selectedTreeId else { return }
        Task { @MainActor in
            let treeExists = (try? TreeStore.shared.getTree(treeId)) != nil
            if !treeExists {
                appState.selectedTreeId = nil
                appState.selectedBranchId = nil
            }
        }
    }
    
    private func startProjectRefresh() {
        ProjectRefreshService.shared.startAutoRefresh()
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
    static let showGlobalSearch = Notification.Name("showGlobalSearch")
}
