import Foundation
import GRDB

@MainActor
final class BranchViewModel: ObservableObject {
    @Published var branch: Branch?
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var isResponding: Bool = false
    @Published var streamingResponse: String = ""
    @Published var error: String?

    private let branchId: String
    private var observation: AnyDatabaseCancellable?
    private var claudeBridge: ClaudeBridge?
    private var responseTask: Task<Void, Never>?

    init(branchId: String) {
        self.branchId = branchId
    }

    func load() {
        isLoading = true
        do {
            branch = try TreeStore.shared.getBranch(branchId)
            if let sessionId = branch?.sessionId {
                messages = try MessageStore.shared.getMessages(sessionId: sessionId)
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    /// Start observing messages for live updates (GRDB ValueObservation)
    func startObserving() {
        guard let dbPool = DatabaseManager.shared.dbPool,
              let sessionId = branch?.sessionId else { return }

        let observation = ValueObservation.tracking { db -> [Message] in
            let sql = """
                SELECT m.*,
                    (SELECT COUNT(*) FROM canvas_branches cb
                     WHERE cb.fork_from_message_id = m.id) as has_branches
                FROM messages m
                WHERE m.session_id = ?
                ORDER BY m.timestamp ASC
                """
            return try Message.fetchAll(db, sql: sql, arguments: [sessionId])
        }

        self.observation = observation.start(in: dbPool, onError: { error in
            Task { @MainActor in
                self.error = error.localizedDescription
            }
        }, onChange: { [weak self] messages in
            Task { @MainActor in
                self?.messages = messages
            }
        })
    }

    func sendMessage() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, let sessionId = branch?.sessionId else { return }
        guard !isResponding else { return }

        inputText = ""

        do {
            // Insert user message
            _ = try MessageStore.shared.sendMessage(
                sessionId: sessionId,
                role: .user,
                content: content
            )
            // Update tree timestamp
            if let treeId = branch?.treeId {
                try TreeStore.shared.updateTreeTimestamp(treeId)
            }
        } catch {
            self.error = error.localizedDescription
            inputText = content
            return
        }

        // Trigger Claude response
        requestResponse(for: content, sessionId: sessionId)
    }

    /// Spawn claude CLI and stream the response back
    private func requestResponse(for message: String, sessionId: String) {
        isResponding = true
        streamingResponse = ""

        let bridge = ClaudeBridge()
        self.claudeBridge = bridge

        // Get working directory from tree
        let cwd = (try? TreeStore.shared.getTree(branch?.treeId ?? ""))?.workingDirectory

        responseTask = Task {
            var accumulated = ""

            let stream = bridge.send(
                message: message,
                conversationHistory: messages,
                model: branch?.model,
                workingDirectory: cwd
            )

            for await chunk in stream {
                accumulated += chunk
                streamingResponse = accumulated
            }

            // Stream complete — save the full response as an assistant message
            let finalResponse = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalResponse.isEmpty {
                do {
                    _ = try MessageStore.shared.sendMessage(
                        sessionId: sessionId,
                        role: .assistant,
                        content: finalResponse
                    )
                } catch {
                    self.error = error.localizedDescription
                }
            }

            streamingResponse = ""
            isResponding = false
            claudeBridge = nil
        }
    }

    func cancelResponse() {
        claudeBridge?.cancel()
        responseTask?.cancel()
        isResponding = false
        streamingResponse = ""
        claudeBridge = nil
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        cancelResponse()
    }
}
