import Foundation
import SwiftUI

// MARK: - Watch Store (TASK-065)
//
// Observable state for the Watch UI.
// Receives events from WatchSessionManager via NotificationCenter.

@MainActor
final class WatchStore: ObservableObject {

    // MARK: - Published State

    @Published var treeName: String = "World Tree"
    @Published var branchName: String? = nil
    @Published var streamingText: String = ""
    @Published var lastMessage: String = ""
    @Published var isStreaming: Bool = false
    @Published var isConnected: Bool = false  // whether iPhone is reachable

    // MARK: - Init

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWatchMessage(_:)),
            name: .watchMessageReceived,
            object: nil
        )
    }

    // MARK: - Message Handling

    @objc private func handleWatchMessage(_ notification: Notification) {
        guard let message = notification.object as? [String: Any],
              let type = message["type"] as? String else { return }

        Task { @MainActor in
            switch type {
            case "streaming_start":
                self.streamingText = ""
                self.isStreaming = true
                if let tree = message["treeName"] as? String {
                    self.treeName = tree
                }
                self.branchName = message["branchName"] as? String
                self.isConnected = true

            case "streaming_token":
                if let token = message["token"] as? String {
                    self.streamingText += token
                }

            case "streaming_end":
                self.lastMessage = self.streamingText
                self.isStreaming = false

            case "context_update":
                if let tree = message["treeName"] as? String {
                    self.treeName = tree
                }
                self.branchName = message["branchName"] as? String
                if let msg = message["lastMessage"] as? String {
                    self.lastMessage = msg
                }
                self.isConnected = true

            case "phone_disconnected":
                self.isConnected = false

            default:
                break
            }
        }
    }
}
