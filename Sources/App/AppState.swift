import Foundation

enum NavigationPanel: String, Hashable {
    case commandCenter
    case tickets
    case scratchpad
    case brain
    case starfleet
    case sessions
    case settings
}

/// Global app state — navigation, system status, selected items.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    // MARK: — Navigation
    var navigationPanel: NavigationPanel = .commandCenter
    var selectedProject: String?
    var selectedTicketId: String?

    // MARK: — Setup
    /// Non-nil if the database failed to initialize — surfaced as an alert in WorldTreeApp.
    var dbSetupError: Error?

    private init() {
        do {
            try DatabaseManager.shared.setup()
        } catch {
            dbSetupError = error
        }
    }
}
