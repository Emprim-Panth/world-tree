import SwiftUI
import UserNotifications

@main
struct WorldTreeApp: App {
    @State private var appState = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

    private let contextServer: ContextServer = {
        let stored = UserDefaults.standard.integer(forKey: "contextServerPort")
        let port = (stored >= 1024 && stored <= 65535) ? UInt16(stored) : 4863
        return ContextServer(port: port)
    }()

    // Held for app lifetime — DispatchSource cancels on deinit
    private let sigtermSource: DispatchSourceSignal = {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            CrashSentinel.shared.markCleanExit()
            NSApplication.shared.terminate(nil)
        }
        src.resume()
        return src
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onAppear {
                    _ = CrashSentinel.shared.checkAndStart()
                    DispatchActivityStore.shared.start()
                    checkForUpdateBadge()

                    if let error = appState.dbSetupError {
                        wtLog("[WorldTree] Database setup failed: \(error)")
                        let alert = NSAlert()
                        alert.messageText = "World Tree — Database Error"
                        alert.informativeText = "Failed to open the database.\n\n\(error.localizedDescription)\n\nCheck that ~/.cortana/claude-memory/ exists."
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

                    guard !AppConstants.isRunningTests else {
                        wtLog("[WorldTree] XCTest detected — skipping production startup")
                        return
                    }

                    // Core data refresh
                    CompassStore.shared.refresh()
                    TicketStore.shared.scanAll()
                    HeartbeatStore.shared.refresh()

                    // Gateway: check for pending handoffs
                    Task {
                        guard let gateway = GatewayClient.fromLocalConfig() else { return }
                        if let handoffs = try? await gateway.checkHandoffs(),
                           !handoffs.filter({ $0.status == "pending" || $0.status == "created" }).isEmpty {
                            wtLog("[WorldTree] \(handoffs.count) pending handoff(s) from gateway")
                        }
                    }

                    // TASK-20: ContextServer — serves project context to Claude sessions
                    contextServer.start()

                    // TASK-45: BrainIndexer — index brain for semantic search
                    Task {
                        BrainIndexer.shared.startWatching()
                        await BrainIndexer.shared.indexAll()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { clearUpdateBadge() }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    CrashSentinel.shared.markCleanExit()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    CompassStore.shared.refresh()
                    TicketStore.shared.scanAll()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            Button("Open World Tree") { NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "tree.fill")
        }
        .menuBarExtraStyle(.menu)
    }

    private func checkForUpdateBadge() {
        if FileManager.default.fileExists(atPath: "/tmp/.worldtree-updated") {
            NSApp.dockTile.badgeLabel = "↑"
        }
    }

    private func clearUpdateBadge() {
        guard NSApp.dockTile.badgeLabel != nil && NSApp.dockTile.badgeLabel != "" else { return }
        NSApp.dockTile.badgeLabel = nil
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/tmp/.worldtree-updated"))
    }
}
