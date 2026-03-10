import SwiftUI

struct ContentView: View {
    @Environment(ConnectionManager.self) private var connectionManager

    private var isIPad: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            switch connectionManager.state {
            case .disconnected where connectionManager.currentServer == nil:
                ServerPickerView()
            default:
                if isIPad && connectionManager.currentServer != nil {
                    iPadRootView()
                } else {
                    mainTabView
                }
            }
        }
    }

    private var mainTabView: some View {
        TabView {
            ConversationView()
                .tabItem {
                    Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                }

            CrewActivityView()
                .tabItem {
                    Label("Crew", systemImage: "person.3")
                }
        }
    }
}
