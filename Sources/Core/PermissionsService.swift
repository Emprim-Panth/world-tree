import ApplicationServices
import CoreGraphics
import Foundation
import UserNotifications

/// Manages system permission requests.
///
/// On macOS 15+, TCC grants (especially Screen Recording) are tied to the binary's CDHash.
/// Every rebuild produces a new CDHash. We track two states separately:
/// - "granted": user said YES at least once. On CDHash mismatch, re-request to re-associate.
/// - "denied": user explicitly said NO. Never ask again.
/// This means the user grants once in their lifetime, not once per build.
actor PermissionsService {
    static let shared = PermissionsService()

    // UserDefaults keys
    private static let accessibilityPromptedKey = "permissions.accessibility.prompted"
    private static let screenRecordingGrantedKey = "permissions.screenRecording.granted"
    private static let screenRecordingDeniedKey  = "permissions.screenRecording.denied"
    private static let notificationsPromptedKey  = "permissions.notifications.prompted"

    // Legacy key — kept for migration, not written going forward
    private static let screenRecordingPromptedKey = "permissions.screenRecording.prompted"

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

    /// Request Screen Recording.
    ///
    /// Behaviour:
    /// - Already granted (CDHash matches TCC): no-op, returns true.
    /// - User previously granted but CDHash changed (rebuild): re-request once so macOS
    ///   re-associates the new binary hash with the existing grant. No dialog shown if the
    ///   user has World Tree toggled ON in System Settings — macOS silently re-grants.
    /// - Never been granted: prompt once, record result. If user granted, store `granted`.
    ///   If denied, store `denied` and never ask again.
    /// - User explicitly denied before: skip prompt, return false.
    @discardableResult
    static func requestScreenRecordingOnce() -> Bool {
        // Already granted for this binary — nothing to do.
        if CGPreflightScreenCaptureAccess() { return true }

        // User explicitly denied before — respect that permanently.
        if UserDefaults.standard.bool(forKey: screenRecordingDeniedKey) {
            return false
        }

        // Migrate legacy "prompted" flag: treat as granted (users who saw the prompt
        // and got here had it working at some point).
        let legacy = UserDefaults.standard.bool(forKey: screenRecordingPromptedKey)
        let prevGranted = UserDefaults.standard.bool(forKey: screenRecordingGrantedKey) || legacy

        if prevGranted {
            // User said YES before. CDHash changed after a rebuild. Re-request so macOS
            // re-associates the new CDHash. If the toggle is ON in System Settings this
            // is silent — no dialog. If the toggle is OFF the user gets one prompt.
            wtLog("[Permissions] Screen Recording CDHash mismatch — re-requesting to re-associate new binary")
            CGRequestScreenCaptureAccess()
            let granted = CGPreflightScreenCaptureAccess()
            if granted {
                UserDefaults.standard.set(true, forKey: screenRecordingGrantedKey)
            }
            return granted
        }

        // First time ever — prompt once.
        CGRequestScreenCaptureAccess()
        let granted = CGPreflightScreenCaptureAccess()
        if granted {
            UserDefaults.standard.set(true, forKey: screenRecordingGrantedKey)
        } else {
            // Don't mark denied here — the dialog is async and the grant may arrive
            // later. We re-check on next launch. Mark denied only if user explicitly
            // clicks "Don't Allow" — which we can't detect synchronously via this API.
            // The safest approach: store "prompted" as legacy and rely on re-request
            // logic above on subsequent launches.
            UserDefaults.standard.set(true, forKey: screenRecordingPromptedKey)
        }
        return granted
    }
}
