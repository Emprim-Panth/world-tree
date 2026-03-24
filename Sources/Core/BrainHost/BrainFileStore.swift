import Foundation

/// Reads and writes BRAIN.md files for each project.
/// - Path convention: ~/Development/{project}/.claude/BRAIN.md
/// - Writes use atomic rename (write to .tmp, then rename) so readers never see partial content.
/// - File watching via DispatchSource — change callbacks fire on the main queue.
@MainActor
final class BrainFileStore: ObservableObject {
    static let shared = BrainFileStore()

    /// Latest content keyed by project name.
    @Published private(set) var content: [String: String] = [:]

    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private let fm = FileManager.default

    private init() {}

    // MARK: — Path

    func brainPath(for project: String) -> URL {
        let home = fm.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Development")
            .appendingPathComponent(project)
            .appendingPathComponent(".claude")
            .appendingPathComponent("BRAIN.md")
    }

    // MARK: — Read

    /// Returns the current content for a project (cached after first read).
    func read(project: String) -> String? {
        if let cached = content[project] { return cached }
        return reload(project: project)
    }

    @discardableResult
    func reload(project: String) -> String? {
        let url = brainPath(for: project)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        content[project] = text
        return text
    }

    // MARK: — Write

    /// Atomically writes new content to BRAIN.md for a project.
    func write(_ text: String, for project: String) throws {
        let dest = brainPath(for: project)
        let dir = dest.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let tmp = dir.appendingPathComponent("BRAIN.md.tmp")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        content[project] = text
    }

    // MARK: — Watch

    /// Starts watching the BRAIN.md for a project. Fires `reload` whenever the file changes.
    func watch(project: String) {
        guard watchers[project] == nil else { return }
        let url = brainPath(for: project)
        let dir = url.deletingLastPathComponent()

        // Ensure the file exists so we can open an fd for it
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }

        guard let fd = open(url.path, O_EVTONLY) != -1 ? open(url.path, O_EVTONLY) : nil else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.reload(project: project)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[project] = source
        wtLog("[BrainFileStore] watching \(project)")
    }

    func stopWatching(project: String) {
        watchers.removeValue(forKey: project)?.cancel()
    }
}
