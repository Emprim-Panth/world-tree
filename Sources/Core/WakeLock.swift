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
    /// Ref-count — multiple simultaneous streams each call acquire/release independently.
    /// The assertion is only created on 0→1 and released on 1→0.
    private var refCount = 0
    private var activityToken: NSObjectProtocol?
    private let lock = NSLock()

    private init() {}

    /// Acquire a no-idle-sleep assertion + App Nap prevention.
    /// Ref-counted — multiple callers are safe; the assertion is created on the first acquire.
    func acquire() {
        lock.withLock {
            refCount += 1
            guard refCount == 1 else { return }  // already held by another stream

            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoIdleSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "World Tree: AI response in progress" as CFString,
                &assertionID
            )

            // Prevent App Nap — keeps timers, network, and streaming running at full speed
            // even when World Tree is behind other windows.
            // .latencyCritical prevents ALL power throttling (main RunLoop, GCD queues, timers).
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "AI streaming response in progress"
            )

            if result == kIOReturnSuccess {
                wtLog("[WakeLock] acquired (assertionID=\(assertionID), appNap=prevented, refCount=\(refCount))")
            } else {
                wtLog("[WakeLock] IOKit acquire failed (result=\(result)), App Nap still prevented")
            }
        }
    }

    /// Release the sleep assertion + App Nap prevention.
    /// Ref-counted — the assertion is only released when all callers have released.
    func release() {
        lock.withLock {
            guard refCount > 0 else { return }
            refCount -= 1
            guard refCount == 0 else { return }  // other streams still running

            IOPMAssertionRelease(assertionID)
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
                activityToken = nil
            }
            wtLog("[WakeLock] released (refCount=0)")
            assertionID = 0
        }
    }

    deinit { release() }
}
