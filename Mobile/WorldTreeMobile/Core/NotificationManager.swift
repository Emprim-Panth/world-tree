import Foundation
import UserNotifications

// MARK: - Notification Category IDs (TASK-062)

private enum NotificationIDs {
    static let assistantMessage = "WORLD_TREE_ASSISTANT_MESSAGE"
    static let replyAction = "WORLD_TREE_REPLY_ACTION"
}

@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    // Callback invoked when the user replies from the lock screen.
    // Set by whoever owns the ConnectionManager (e.g. WorldTreeStore).
    var onLockScreenReply: ((String) -> Void)?

    private override init() {
        super.init()
    }

    /// Request authorization and register the reply action category.
    /// Safe to call every launch — UNUserNotificationCenter ignores duplicate category registrations.
    func requestAuthorization() {
        // Register notification categories (TASK-062: reply action)
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationIDs.replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply to Cortana…"
        )
        let category = UNNotificationCategory(
            identifier: NotificationIDs.assistantMessage,
            actions: [replyAction],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "New message from Cortana",
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().delegate = self

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
        content.categoryIdentifier = NotificationIDs.assistantMessage

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate (TASK-062)

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// Deliver notifications in-app when World Tree is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound in-app only if we're not currently in the same branch.
        // This fires even when the app is active — let it through so the user sees
        // responses on other conversations.
        completionHandler([.banner, .sound])
    }

    /// Handle the reply text input action from the lock screen / notification banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        guard response.actionIdentifier == NotificationIDs.replyAction,
              let textResponse = response as? UNTextInputNotificationResponse,
              !textResponse.userText.isEmpty
        else { return }

        let replyText = textResponse.userText
        Task { @MainActor in
            NotificationManager.shared.onLockScreenReply?(replyText)
        }
    }
}
