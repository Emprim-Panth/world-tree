import Foundation
import WatchConnectivity

// MARK: - Watch Session Manager (TASK-065)
//
// Handles the WCSession lifecycle on the Watch side.
// Receives messages from the iPhone:
//   "type": "streaming_start"  — Cortana is starting a response
//   "type": "streaming_token"  — new text chunk (appended to display)
//   "type": "streaming_end"    — response complete
//   "type": "context_update"   — tree/branch name update
//
// Forwards them to WatchStore via NotificationCenter.

final class WatchSessionManager: NSObject {
    static let shared = WatchSessionManager()

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) { }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        NotificationCenter.default.post(
            name: .watchMessageReceived,
            object: message
        )
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        NotificationCenter.default.post(
            name: .watchMessageReceived,
            object: message
        )
        replyHandler(["status": "ok"])
    }
}

extension Notification.Name {
    static let watchMessageReceived = Notification.Name("WatchMessageReceived")
}
