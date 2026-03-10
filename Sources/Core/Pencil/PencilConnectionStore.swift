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

    // MARK: - Screenshot Cache

    /// In-memory cache: frameId → PNG Data (cleared on disconnect)
    private(set) var screenshotCache: [String: Data] = [:]

    // MARK: - Filesystem Watcher

    private struct WatchedAsset {
        let assetId: String
        let project: String
        let path: String
        var modDate: Date?
    }

    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]   // key: dir path
    private var watchedAssets: [WatchedAsset] = []
    private let watcherQueue = DispatchQueue(label: "pencil.filewatcher", qos: .utility)

    // MARK: - Init

    init(client: PencilMCPClient = PencilMCPClient()) {
        self.client = client
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard pingTask == nil else { return }

        Task { await startWatching() }

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
        stopWatching()
    }

    // MARK: - Screenshot

    /// Returns a PNG screenshot of the given frame.
    /// Result is cached per frameId — call again to refresh.
    func getFrameScreenshot(frameId: String) async throws -> Data {
        if let cached = screenshotCache[frameId] { return cached }
        let data = try await client.getFrameScreenshot(frameId: frameId)
        screenshotCache[frameId] = data
        return data
    }

    func invalidateScreenshotCache(for frameId: String) {
        screenshotCache.removeValue(forKey: frameId)
    }

    // MARK: - Filesystem Watcher

    /// Loads all imported .pen file paths from the DB and installs directory watchers.
    func startWatching() async {
        guard let pool = DatabaseManager.shared.dbPool else { return }
        do {
            let assets = try await pool.read { db in
                try PenAsset.fetchAll(db, sql: "SELECT * FROM pen_assets")
            }
            for asset in assets {
                addWatcher(for: asset.filePath, assetId: asset.id, project: asset.project)
            }
        } catch { }
    }

    /// Install a watcher for a newly imported .pen file.
    /// Safe to call repeatedly — only one watcher per directory is installed.
    func addWatcher(for path: String, assetId: String, project: String) {
        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        watchedAssets.removeAll { $0.assetId == assetId }
        watchedAssets.append(WatchedAsset(assetId: assetId, project: project, path: path, modDate: modDate))

        let dirPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard fileWatchers[dirPath] == nil else { return }

        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.checkAndReimportChanged(inDirectory: dirPath)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatchers[dirPath] = source
    }

    func stopWatching() {
        for (_, source) in fileWatchers { source.cancel() }
        fileWatchers = [:]
        watchedAssets = []
    }

    private func checkAndReimportChanged(inDirectory dirPath: String) async {
        let inDir = watchedAssets.filter {
            URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == dirPath
        }
        for asset in inDir {
            let currentMod = (try? FileManager.default.attributesOfItem(atPath: asset.path)[.modificationDate]) as? Date
            guard let current = currentMod, current != asset.modDate else { continue }

            if let idx = watchedAssets.firstIndex(where: { $0.assetId == asset.assetId }) {
                watchedAssets[idx].modDate = current
            }
            // Invalidate screenshot cache for all frames in this asset (we don't track them here)
            screenshotCache = [:]

            let url = URL(fileURLWithPath: asset.path)
            try? await PenAssetStore.shared.importFile(at: url, project: asset.project)
            NotificationCenter.default.post(name: .pencilAssetUpdated, object: asset.assetId)
        }
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
                screenshotCache = [:]
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
