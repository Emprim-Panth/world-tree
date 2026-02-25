import Foundation
import IOKit.pwr_mgt

/// Prevents system idle sleep while an AI response is in progress.
/// Uses IOKit power management — no Accessibility permission required.
final class WakeLock {
    static let shared = WakeLock()

    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false
    private let lock = NSLock()

    private init() {}

    /// Acquire a no-idle-sleep assertion. Safe to call multiple times — only acquires once.
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
            if isHeld {
                wtLog("[WakeLock] acquired (assertionID=\(assertionID))")
            } else {
                wtLog("[WakeLock] acquire failed (result=\(result))")
            }
        }
    }

    /// Release the sleep assertion. Safe to call when not held.
    func release() {
        lock.withLock {
            guard isHeld else { return }
            IOPMAssertionRelease(assertionID)
            wtLog("[WakeLock] released")
            isHeld = false
            assertionID = 0
        }
    }

    deinit { release() }
}
