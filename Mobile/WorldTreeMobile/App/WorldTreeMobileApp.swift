import SwiftUI

@main
struct WorldTreeMobileApp: App {
    @State private var connectionManager = ConnectionManager()
    @State private var store = WorldTreeStore()

    init() {
        NotificationManager.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .environment(store)
                .preferredColorScheme(.dark)
                // Handoff: continue a branch from macOS or another iOS device
                .onContinueUserActivity("com.evanprimeau.worldtree.viewBranch") { activity in
                    guard let treeId = activity.userInfo?["treeId"] as? String,
                          let branchId = activity.userInfo?["branchId"] as? String else { return }
                    store.pendingHandoff = HandoffRequest(treeId: treeId, branchId: branchId)
                }
        }
    }
}
