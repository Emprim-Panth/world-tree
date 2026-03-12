import Foundation
import IOKit.pwr_mgt

/// Prevents system idle sleep AND App Nap while an AI response is in progress.
/// Uses IOKit power management + ProcessInfo activity assertion.
///
/// WakeLock prevents idle sleep (display + system).
/// App Nap prevention ensures macOS doesn't throttle background streaming
/// when World Tree is occluded behind other windows.
final class WakeLock {
    static let shared = WakeLock()

    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false
    private var activityToken: NSObjectProtocol?
    private let lock = NSLock()

    private init() {}

    /// Acquire a no-idle-sleep assertion + App Nap prevention.
    /// Safe to call multiple times — only acquires once.
    func acquire() {
        lock.withLock {
            guard !isHeld else { return }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "World Tree: AI response in progress" as CFString,
                &assertionID
            )
            isHeld = result == kIOReturnSuccess

            // Prevent App Nap — keeps timers, network, and streaming running at full speed
            // even when World Tree is behind other windows.
            // .latencyCritical prevents ALL power throttling (main RunLoop, GCD queues, timers).
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "AI streaming response in progress"
            )

            if isHeld {
                wtLog("[WakeLock] acquired (assertionID=\(assertionID), appNap=prevented)")
            } else {
                wtLog("[WakeLock] IOKit acquire failed (result=\(result)), App Nap still prevented")
            }
        }
    }

    /// Release the sleep assertion + App Nap prevention. Safe to call when not held.
    func release() {
        lock.withLock {
            guard isHeld else { return }
            IOPMAssertionRelease(assertionID)
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
                activityToken = nil
            }
            wtLog("[WakeLock] released")
            isHeld = false
            assertionID = 0
        }
    }

    deinit { release() }
}
