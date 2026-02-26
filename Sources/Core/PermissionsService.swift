import Foundation
import UserNotifications
import AVFoundation
import Speech
import CoreGraphics

/// Manages system permission requests — checks and requests on every launch.
///
/// TCC grants are tied to the app's code signature. With a stable Developer certificate,
/// grants persist indefinitely. We check status on every launch rather than relying on a
/// first-launch flag — this ensures we re-prompt if any permission is lost (e.g. after
/// a macOS update or System Settings reset).
///
/// Requesting a permission that is already granted is always a no-op (no dialog shown).
actor PermissionsService {
    static let shared = PermissionsService()

    private init() {}

    /// Call once on app launch.
    ///
    /// Always wires the notification delegate (required every launch for notification taps).
    /// Checks all permission statuses and requests any that are not yet granted.
    func setup() async {
        // Notification delegate must be registered on every launch — not just first.
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        }

        await requestNotificationsIfNeeded()
        _ = await VoiceService.shared.requestPermissions()
        requestScreenRecordingIfNeeded()
        requestAccessibilityIfNeeded()
    }

    // MARK: - Notifications

    private func requestNotificationsIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        await NotificationManager.shared.requestAuthorization()
    }

    // MARK: - Screen Recording

    /// Requests Screen Recording access if not already granted.
    /// Required for PeekabooBridgeServer (ScreenCaptureKit).
    /// On macOS 14+, CGRequestScreenCaptureAccess() directs the user to System Settings.
    private func requestScreenRecordingIfNeeded() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Accessibility

    /// Requests Accessibility (AX) access if not already trusted.
    /// Used for window listing and UI inspection by peekaboo and shell integrations.
    private func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
