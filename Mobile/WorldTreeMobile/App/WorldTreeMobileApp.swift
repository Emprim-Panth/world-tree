import SwiftUI

// MARK: - Share Extension constants (mirrors ShareViewController.ShareConstants)
private enum AppGroupKeys {
    static let suiteName = "group.com.evanprimeau.worldtree"
    static let pendingShareText = "pendingShareText"
    static let pendingShareURL = "pendingShareURL"
}

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
                // Share Extension: worldtree://newbranch?text=<encoded>&sourceURL=<encoded>
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    // MARK: - URL Scheme Handler

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "worldtree",
              url.host == "newbranch" else { return }

        // Prefer full text from App Group storage (may be longer than the URL query param).
        let shareText: String?
        let shareURL: String?

        if let suite = UserDefaults(suiteName: AppGroupKeys.suiteName) {
            shareText = suite.string(forKey: AppGroupKeys.pendingShareText)
            shareURL  = suite.string(forKey: AppGroupKeys.pendingShareURL)
            // Clear immediately so stale data doesn't re-trigger on next cold launch.
            suite.removeObject(forKey: AppGroupKeys.pendingShareText)
            suite.removeObject(forKey: AppGroupKeys.pendingShareURL)
            suite.synchronize()
        } else {
            // Fallback: read from URL query params if App Group isn't available.
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            shareText = components?.queryItems?.first(where: { $0.name == "text" })?.value
            shareURL  = components?.queryItems?.first(where: { $0.name == "sourceURL" })?.value
        }

        guard let text = shareText, !text.isEmpty else { return }

        store.pendingShare = PendingShare(text: text, sourceURL: shareURL)
    }
}
