import Foundation
import GRDB

@MainActor
final class BranchViewModel: ObservableObject {
    @Published var branch: Branch?
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isLoading: Bool = false
    @Published var error: String?

    private let branchId: String
    private var observation: AnyDatabaseCancellable?

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

        inputText = ""

        do {
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
            inputText = content // Restore on failure
        }
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }
}
