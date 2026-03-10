import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

/// Manages system permission requests — prompt once, then never again.
///
/// On macOS 26+, TCC grants (especially Screen Recording) are tied to the binary's CDHash.
/// Every rebuild produces a new CDHash, invalidating the grant. Prompting every launch is
/// hostile — the user said yes once, they meant it. We track that in UserDefaults and
/// silently degrade if the grant was invalidated by a rebuild. The user can re-grant in
/// System Settings → Privacy & Security if a feature stops working.
actor PermissionsService {
    static let shared = PermissionsService()

    // UserDefaults keys — once prompted, never prompt again
    private static let accessibilityPromptedKey = "permissions.accessibility.prompted"
    private static let screenRecordingPromptedKey = "permissions.screenRecording.prompted"
    private static let notificationsPromptedKey = "permissions.notifications.prompted"

    private init() {}

    /// Call once on app launch.
    ///
    /// Always wires the notification delegate (required every launch for notification taps).
    /// Only prompts for permissions that have NEVER been prompted before.
    ///
    /// Voice permissions are deferred to first use (VoiceControlViewModel.toggleListening).
    /// Screen Recording is deferred to PeekabooBridgeServer.start().
    func setup() async {
        // Notification delegate must be registered on every launch — not just first.
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        }

        await requestNotificationsIfNeeded()
        requestAccessibilityIfNeeded()
    }

    // MARK: - Notifications

    private func requestNotificationsIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.notificationsPromptedKey) else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        await NotificationManager.shared.requestAuthorization()
        UserDefaults.standard.set(true, forKey: Self.notificationsPromptedKey)
    }

    // MARK: - Accessibility

    /// Requests Accessibility (AX) access ONCE. After the first prompt, never prompt again.
    /// If a rebuild invalidates the TCC grant, features that need AX silently degrade.
    private func requestAccessibilityIfNeeded() {
        // Already granted — nothing to do
        guard !AXIsProcessTrusted() else { return }
        // Already prompted before — don't harass the user after a rebuild
        guard !UserDefaults.standard.bool(forKey: Self.accessibilityPromptedKey) else {
            wtLog("[Permissions] Accessibility not trusted (grant likely invalidated by rebuild) — skipping prompt")
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedKey)
    }

    // MARK: - Screen Recording

    /// Check if Screen Recording is available. Returns true if granted, false otherwise.
    /// Never prompts — call `requestScreenRecordingOnce()` for the one-time prompt.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request Screen Recording permission ONCE. After the first prompt, never prompt again.
    /// Returns true if currently granted, false if not (even if we just prompted).
    @discardableResult
    static func requestScreenRecordingOnce() -> Bool {
        // Already granted — nothing to do
        if CGPreflightScreenCaptureAccess() { return true }
        // Already prompted before — don't re-prompt after a rebuild invalidated the grant
        if UserDefaults.standard.bool(forKey: screenRecordingPromptedKey) {
            wtLog("[Permissions] Screen Recording not granted (grant likely invalidated by rebuild) — skipping prompt")
            return false
        }
        CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: screenRecordingPromptedKey)
        return CGPreflightScreenCaptureAccess()
    }
}
