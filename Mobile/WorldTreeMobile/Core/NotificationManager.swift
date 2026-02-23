import Foundation
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Fire a local notification for an incoming assistant message.
    /// iOS silently drops this when the app is in the foreground (no delegate = no in-app banner),
    /// so it only appears when the user is away from the conversation.
    func notifyAssistantMessage(treeName: String, branchName: String?, text: String) {
        let content = UNMutableNotificationContent()
        content.title = treeName
        if let branch = branchName, !branch.isEmpty, branch.lowercased() != "main" {
            content.subtitle = branch
        }
        content.body = text.isEmpty ? "New message" : String(text.prefix(200))
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
