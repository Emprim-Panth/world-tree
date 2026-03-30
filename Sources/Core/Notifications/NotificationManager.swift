import Foundation
import AppKit
import UserNotifications

// MARK: - Notification Delegate

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        if response.actionIdentifier == "VIEW" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Notification Manager

actor NotificationManager {
    static let shared = NotificationManager()
    private var isAuthorized = false

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .denied:
            isAuthorized = false
        case .notDetermined:
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                wtLog("[NotificationManager] Authorization request failed: \(error)")
                isAuthorized = false
            }
        @unknown default:
            isAuthorized = false
        }
        wtLog("[NotificationManager] authorized: \(isAuthorized)")
    }

    func notify(title: String, body: String, sound: Bool = true) async {
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            wtLog("[NotificationManager] Failed to deliver notification: \(error)")
        }
    }
}
