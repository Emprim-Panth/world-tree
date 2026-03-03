import SwiftUI
import WatchConnectivity

// MARK: - Watch App Entry Point (TASK-065)
//
// World Tree Watch companion — receives live streaming text from the iPhone
// via WatchConnectivity (sendMessage for real-time updates) and displays
// the current Cortana response on the wrist.

@main
struct WorldTreeWatchApp: App {
    @StateObject private var watchStore = WatchStore()

    init() {
        WatchSessionManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(watchStore)
        }
    }
}
