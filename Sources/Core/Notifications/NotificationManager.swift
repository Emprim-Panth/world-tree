import Foundation
import AppKit
import UserNotifications

// MARK: - Notification Delegate

/// Handles notification action responses (COPY, VIEW) delivered by UNUserNotificationCenter.
/// Stored as a long-lived singleton and set as UNUserNotificationCenter.delegate on launch.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        switch response.actionIdentifier {
        case "COPY":
            let userInfo = response.notification.request.content.userInfo
            guard let jobId = userInfo["jobId"] as? String else { return }
            Task { @MainActor in
                if let job = try? DatabaseManager.shared.read({ db in
                    try WorldTreeJob.fetchOne(db, key: jobId)
                }) {
                    let text = job.output ?? job.command
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }

        case "VIEW", UNNotificationDefaultActionIdentifier:
            NSApp.activate(ignoringOtherApps: true)

        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner + sound even when app is in foreground
        completionHandler([.banner, .sound])
    }
}

// MARK: - Notification Manager

/// Manages macOS notifications for Canvas events.
actor NotificationManager {
    static let shared = NotificationManager()

    private var isAuthorized = false

    // MARK: - Setup

    /// Request notification permissions. Call on app launch.
    /// Only shows the system dialog when status is .notDetermined — skips the prompt if already decided.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
            wtLog("[NotificationManager] authorization: already granted")
        case .denied:
            isAuthorized = false
            wtLog("[NotificationManager] authorization: denied")
        case .notDetermined:
            do {
                isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                wtLog("[NotificationManager] authorization: \(isAuthorized)")
            } catch {
                wtLog("[NotificationManager] auth error: \(error)")
            }
        @unknown default:
            isAuthorized = false
        }

        // Register action categories
        let viewAction = UNNotificationAction(identifier: "VIEW", title: "View", options: .foreground)
        let copyAction = UNNotificationAction(identifier: "COPY", title: "Copy Output", options: [])

        let jobCategory = UNNotificationCategory(
            identifier: "JOB_COMPLETE",
            actions: [viewAction, copyAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([jobCategory])
    }

    // MARK: - Job Notifications

    func notifyJobComplete(_ job: WorldTreeJob) async {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()

        if job.status == .completed {
            content.title = "Job Complete"
            content.body = job.displayCommand
            content.sound = .default
        } else if job.status == .failed {
            content.title = "Job Failed"
            content.body = "\(job.displayCommand)\n\(job.error ?? "Unknown error")"
            content.sound = UNNotificationSound.defaultCritical
        } else {
            return // Don't notify for other statuses
        }

        content.categoryIdentifier = "JOB_COMPLETE"
        content.userInfo = ["jobId": job.id]

        let request = UNNotificationRequest(
            identifier: "job-\(job.id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            wtLog("[NotificationManager] failed to send notification: \(error)")
        }
    }

    // MARK: - Generic Notification

    func notify(title: String, body: String, sound: Bool = true) async {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await UNUserNotificationCenter.current().add(request)
    }
}
