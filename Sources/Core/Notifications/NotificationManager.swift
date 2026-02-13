import Foundation
import UserNotifications

/// Manages macOS notifications for Canvas events.
actor NotificationManager {
    static let shared = NotificationManager()

    private var isAuthorized = false

    // MARK: - Setup

    /// Request notification permissions. Call on app launch.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            canvasLog("[NotificationManager] authorization: \(isAuthorized)")
        } catch {
            canvasLog("[NotificationManager] auth error: \(error)")
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

    func notifyJobComplete(_ job: CanvasJob) async {
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
            canvasLog("[NotificationManager] failed to send notification: \(error)")
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
