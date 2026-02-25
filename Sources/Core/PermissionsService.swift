import Foundation
import UserNotifications
import AVFoundation
import Speech
import CoreGraphics

/// Manages system permission requests — requests all on first launch, never again.
///
/// On first install, sequentially prompts for:
///   - Notifications
///   - Microphone + Speech Recognition (voice features)
///   - Screen Recording (PeekabooBridge / ScreenCaptureKit)
///
/// On subsequent launches, the notification delegate is re-wired (required for handling
/// notification interactions) but no permission dialogs appear — the OS remembers grants/denials.
actor PermissionsService {
    static let shared = PermissionsService()

    private let firstLaunchKey = "com.forgeandcode.world-tree.permissionsRequested"

    private init() {}

    /// Call once on app launch.
    ///
    /// Always wires the notification delegate (required every launch for notification taps).
    /// Shows system permission dialogs only on the very first launch.
    func setup() async {
        // Notification delegate must be registered on every launch — not just first.
        await MainActor.run {
            UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        }

        let alreadyAsked = await MainActor.run {
            UserDefaults.standard.bool(forKey: firstLaunchKey)
        }

        guard !alreadyAsked else { return }

        // First launch — request all permissions up front so they're never asked again.
        await requestNotifications()
        _ = await VoiceService.shared.requestPermissions()
        requestScreenRecording()

        await MainActor.run {
            UserDefaults.standard.set(true, forKey: firstLaunchKey)
        }
    }

    private func requestNotifications() async {
        await NotificationManager.shared.requestAuthorization()
    }

    /// Triggers the screen recording TCC prompt (or opens System Settings if previously denied).
    /// Required for PeekabooBridgeServer — uses ScreenCaptureKit.
    private func requestScreenRecording() {
        guard !CGPreflightScreenCaptureAccess() else { return }
        CGRequestScreenCaptureAccess()
    }
}
