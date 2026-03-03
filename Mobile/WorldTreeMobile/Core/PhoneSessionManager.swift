import Foundation
import WatchConnectivity

// MARK: - Phone Session Manager (TASK-065)
//
// Manages WCSession on the iPhone side.
// Sends streaming events to the Watch companion app so the wrist shows
// Cortana's response in real time.
//
// Messages sent:
//   streaming_start   — when addOptimisticMessage fires (user sends a message)
//   streaming_token   — on each token batch (coalesced to 1/sec to avoid flooding)
//   streaming_end     — on message_complete
//   context_update    — when tree/branch changes (so Watch always shows current context)

@MainActor
final class PhoneSessionManager: NSObject {

    static let shared = PhoneSessionManager()

    private override init() { super.init() }

    // MARK: - Lifecycle

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Send Helpers

    private var tokenBuffer: String = ""
    private var tokenFlushScheduled = false

    func sendStreamingStart(treeName: String, branchName: String?) {
        tokenBuffer = ""
        tokenFlushScheduled = false
        sendIfReachable([
            "type": "streaming_start",
            "treeName": treeName,
            "branchName": branchName as Any
        ])
    }

    func bufferToken(_ token: String) {
        tokenBuffer += token
        if !tokenFlushScheduled {
            tokenFlushScheduled = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1000))
                await self?.flushTokenBuffer()
            }
        }
    }

    func sendStreamingEnd(finalText: String) {
        // Flush any remaining buffered tokens before ending
        if !tokenBuffer.isEmpty {
            sendIfReachable(["type": "streaming_token", "token": tokenBuffer])
            tokenBuffer = ""
        }
        tokenFlushScheduled = false
        sendIfReachable([
            "type": "streaming_end",
            "finalText": String(finalText.prefix(500))
        ])
    }

    func sendContextUpdate(treeName: String, branchName: String?, lastMessage: String) {
        sendIfReachable([
            "type": "context_update",
            "treeName": treeName,
            "branchName": branchName as Any,
            "lastMessage": String(lastMessage.prefix(500))
        ])
    }

    // MARK: - Private

    private func flushTokenBuffer() {
        tokenFlushScheduled = false
        guard !tokenBuffer.isEmpty else { return }
        sendIfReachable(["type": "streaming_token", "token": tokenBuffer])
        tokenBuffer = ""
    }

    private func sendIfReachable(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) { }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { }
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
