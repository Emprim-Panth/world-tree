import Foundation

struct PendingStreamRecovery: Codable, Equatable {
    enum Reason: String, Codable {
        case interruptedStream
    }

    let sessionId: String
    let createdAt: Date
    let reason: Reason
    let partialContent: String
    let attemptCount: Int
    let lastAttemptAt: Date?

    init(
        sessionId: String,
        createdAt: Date,
        reason: Reason,
        partialContent: String = "",
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.reason = reason
        self.partialContent = partialContent
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId
        case createdAt
        case reason
        case partialContent
        case attemptCount
        case lastAttemptAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        reason = try container.decode(Reason.self, forKey: .reason)
        partialContent = try container.decodeIfPresent(String.self, forKey: .partialContent) ?? ""
        attemptCount = try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    }
}

@MainActor
final class StreamRecoveryStore {
    static let shared = StreamRecoveryStore()

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        storageKey: String = "worldtree.pending-stream-recoveries"
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.storageKey = storageKey
    }

    func pendingRecovery(for sessionId: String) -> PendingStreamRecovery? {
        loadState()[sessionId]
    }

    func hasPendingRecovery(sessionId: String) -> Bool {
        pendingRecovery(for: sessionId) != nil
    }

    func allPendingSessionIds() -> [String] {
        Array(loadState().keys)
    }

    func markPending(
        sessionId: String,
        partialContent: String = "",
        reason: PendingStreamRecovery.Reason = .interruptedStream
    ) {
        var state = loadState()
        // Always preserve the existing attemptCount regardless of content changes.
        // Previous design reset on content change, but that creates infinite crash loops:
        // each recovery attempt receives a few tokens (slightly different content) which
        // triggered a count reset, defeating the maxAttempts limit entirely.
        let existingCount = state[sessionId]?.attemptCount ?? 0
        state[sessionId] = PendingStreamRecovery(
            sessionId: sessionId,
            createdAt: state[sessionId]?.createdAt ?? Date(),
            reason: reason,
            partialContent: partialContent,
            attemptCount: existingCount
        )
        saveState(state, changedSessionId: sessionId)
    }

    @discardableResult
    func markAttemptStarted(sessionId: String) -> PendingStreamRecovery? {
        var state = loadState()
        guard let current = state[sessionId] else { return nil }

        let updated = PendingStreamRecovery(
            sessionId: current.sessionId,
            createdAt: current.createdAt,
            reason: current.reason,
            partialContent: current.partialContent,
            attemptCount: current.attemptCount + 1,
            lastAttemptAt: Date()
        )
        state[sessionId] = updated
        saveState(state, changedSessionId: sessionId)
        return updated
    }

    @discardableResult
    func updatePartialContent(sessionId: String, partialContent: String) -> PendingStreamRecovery? {
        var state = loadState()
        guard let current = state[sessionId] else { return nil }

        let updated = PendingStreamRecovery(
            sessionId: current.sessionId,
            createdAt: current.createdAt,
            reason: current.reason,
            partialContent: partialContent,
            attemptCount: current.attemptCount,
            lastAttemptAt: current.lastAttemptAt
        )
        state[sessionId] = updated
        saveState(state, changedSessionId: sessionId)
        return updated
    }

    func clearPending(sessionId: String) {
        var state = loadState()
        guard state.removeValue(forKey: sessionId) != nil else { return }
        saveState(state, changedSessionId: sessionId)
    }

    private func loadState() -> [String: PendingStreamRecovery] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: PendingStreamRecovery].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func saveState(_ state: [String: PendingStreamRecovery], changedSessionId: String) {
        if state.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: storageKey)
        }

        notificationCenter.post(
            name: .streamRecoveryStateChanged,
            object: nil,
            userInfo: ["sessionId": changedSessionId]
        )
    }
}

extension Notification.Name {
    static let streamRecoveryStateChanged = Notification.Name("streamRecoveryStateChanged")
}
