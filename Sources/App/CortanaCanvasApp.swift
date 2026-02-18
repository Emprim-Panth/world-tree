import SwiftUI

@main
struct CortanaCanvasApp: App {
    @StateObject private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setupDatabase()
                    validateRestoredSelection()
                    startProjectRefresh()
                    requestNotificationPermission()
                    startCanvasServerIfEnabled()
                    Task { await VoiceService.shared.configure() }
                }
                .onChange(of: scenePhase) { _, phase in
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
            }
        }

        Settings {
            SettingsView()
        }
    }

    private func setupDatabase() {
        do {
            try DatabaseManager.shared.setup()
            JobQueue.configure() // Share dbPool with background job queue
        } catch {
            canvasLog("[Canvas] Database setup failed: \(error)")
            // Surface the failure to the user — the app cannot function without a database.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Cortana Canvas — Database Error"
                alert.informativeText = "Failed to open the conversation database.\n\n\(error.localizedDescription)\n\nCheck that the Dropbox path is accessible, or configure a different database path in Settings."
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
        }
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

    private func requestNotificationPermission() {
        Task {
            await NotificationManager.shared.requestAuthorization()
        }
    }

    private func startCanvasServerIfEnabled() {
        guard UserDefaults.standard.bool(forKey: CanvasServer.enabledKey) else { return }
        CanvasServer.shared.start()
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let createNewTree = Notification.Name("createNewTree")
    static let createNewBranch = Notification.Name("createNewBranch")
}
