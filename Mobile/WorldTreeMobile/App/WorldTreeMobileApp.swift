import SwiftUI

@main
struct WorldTreeMobileApp: App {
    @State private var connectionManager = ConnectionManager()
    @State private var store = WorldTreeStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connectionManager)
                .environment(store)
        }
    }
}
