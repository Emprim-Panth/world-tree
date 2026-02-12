import SwiftUI

@main
struct CortanaCanvasApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setupDatabase()
                    startProjectRefresh()
                    requestNotificationPermission()
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
            print("[Canvas] Database setup failed: \(error)")
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
}

// MARK: - Notifications

extension Notification.Name {
    static let createNewTree = Notification.Name("createNewTree")
    static let createNewBranch = Notification.Name("createNewBranch")
}
