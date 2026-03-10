import Foundation

// MARK: - PencilConnectionStore

/// Observable connection state between World Tree and Pencil's local MCP server.
///
/// UI observes this store — it never touches PencilMCPClient directly.
/// Polling runs on a background Task, publishing state changes to @MainActor.
@MainActor
final class PencilConnectionStore: ObservableObject {
    static let shared = PencilConnectionStore()

    // MARK: - Published State

    @Published private(set) var isConnected: Bool = false
    @Published private(set) var lastEditorState: PencilEditorState?
    @Published private(set) var lastLayout: PencilLayout?
    @Published private(set) var lastVariables: [PencilVariable] = []
    @Published private(set) var lastError: String?

    // MARK: - Private

    private let client: PencilMCPClient
    private var pingTask: Task<Void, Never>?
    private var dataTask: Task<Void, Never>?

    private let pingInterval: UInt64 = 5_000_000_000    // 5s
    private let dataInterval: UInt64 = 30_000_000_000   // 30s

    // MARK: - Init

    init(client: PencilMCPClient = PencilMCPClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard pingTask == nil else { return }

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.performPing()
                try? await Task.sleep(nanoseconds: self?.pingInterval ?? 5_000_000_000)
            }
        }
    }

    func stopPolling() {
        pingTask?.cancel()
        pingTask = nil
        dataTask?.cancel()
        dataTask = nil
    }

    /// One-shot full refresh — called by Settings "Test Connection" button and UI refresh
    func refreshNow() async {
        await performPing()
        if isConnected {
            await fetchCanvasData()
        }
    }

    // MARK: - Internal

    private func performPing() async {
        let alive = await client.ping()
        let wasConnected = isConnected
        isConnected = alive

        if alive {
            lastError = nil
            // First connection or data task not running — kick off data fetch
            if !wasConnected || dataTask == nil || dataTask?.isCancelled == true {
                await fetchCanvasData()
                startDataPolling()
            }
        } else {
            if wasConnected {
                // Just disconnected — clear stale data
                lastEditorState = nil
                lastLayout = nil
                lastVariables = []
            }
            stopDataPolling()
        }
    }

    private func startDataPolling() {
        guard dataTask == nil || dataTask?.isCancelled == true else { return }
        dataTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.dataInterval ?? 30_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.fetchCanvasData()
            }
        }
    }

    private func stopDataPolling() {
        dataTask?.cancel()
        dataTask = nil
    }

    private func fetchCanvasData() async {
        async let editorState = fetchEditorState()
        async let layout = fetchLayout()
        async let variables = fetchVariables()

        lastEditorState = await editorState
        lastLayout = await layout
        lastVariables = await variables ?? []
    }

    private func fetchEditorState() async -> PencilEditorState? {
        do {
            return try await client.getEditorState()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func fetchLayout() async -> PencilLayout? {
        do {
            return try await client.snapshotLayout()
        } catch {
            return nil
        }
    }

    private func fetchVariables() async -> [PencilVariable]? {
        do {
            return try await client.getVariables()
        } catch {
            return nil
        }
    }
}
