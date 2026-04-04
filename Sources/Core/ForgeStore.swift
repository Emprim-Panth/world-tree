import Foundation
import AppKit
import Observation

// MARK: - FileNode

/// A node in the Forge file tree. Directories load children lazily on first expand.
@MainActor
final class FileNode: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    let isDirectory: Bool

    /// Child nodes — nil means not yet loaded.
    var children: [FileNode]?
    var isExpanded: Bool = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var icon: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "md":          return "doc.text.fill"
        case "yaml", "yml": return "gearshape.fill"
        case "json":        return "curlybraces"
        case "db", "sqlite": return "cylinder.fill"
        case "sh":          return "terminal.fill"
        case "toml":        return "gearshape.2.fill"
        case "py":          return "chevron.left.forwardslash.chevron.right"
        case "swift":       return "swift"
        case "log":         return "doc.plaintext.fill"
        default:            return "doc.fill"
        }
    }

    /// Returns a Palette-friendly color name for the node.
    var colorTag: NodeColor {
        if isDirectory { return .cyan }
        switch url.pathExtension.lowercased() {
        case "md":          return .blue
        case "yaml", "yml": return .orange
        case "json":        return .yellow
        case "db", "sqlite": return .purple
        case "sh":          return .green
        case "toml":        return .orange
        case "swift":       return .orange
        default:            return .secondary
        }
    }

    enum NodeColor { case cyan, blue, orange, yellow, purple, green, secondary }
}

// MARK: - ForgeBookmark

struct ForgeBookmark: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let relativePath: String  // relative to ~/.cortana/
}

// MARK: - ForgeStore

/// Data layer for The Forge file browser — browses and edits files under ~/.cortana/.
@MainActor
@Observable
final class ForgeStore {
    static let shared = ForgeStore()

    // MARK: - State

    /// Root nodes of the ~/.cortana/ tree
    private(set) var rootNodes: [FileNode] = []

    /// Currently selected file URL
    var selectedURL: URL?

    /// Content of the selected file (nil for directories or unreadable files)
    var selectedContent: String?

    /// True if the selected file is being edited
    var isEditing: Bool = false

    /// Draft content while editing
    var draftContent: String = ""

    /// True if draft differs from saved content
    var isDirty: Bool { isEditing && draftContent != (selectedContent ?? "") }

    /// Show delete confirmation alert
    var showDeleteConfirm: Bool = false
    var pendingDeleteURL: URL?

    /// Show rename sheet
    var showRenameSheet: Bool = false
    var pendingRenameURL: URL?
    var renameText: String = ""

    /// Error message to surface in UI
    var errorMessage: String?
    var showError: Bool = false

    // MARK: - Bookmarks

    let bookmarks: [ForgeBookmark] = [
        ForgeBookmark(name: "Brain",      icon: "brain.head.profile",       relativePath: "brain"),
        ForgeBookmark(name: "Agents",     icon: "person.2.badge.gearshape", relativePath: "agents"),
        ForgeBookmark(name: "Memory",     icon: "note.text",                relativePath: "claude-memory"),
        ForgeBookmark(name: "Config",     icon: "gearshape.fill",           relativePath: "config"),
        ForgeBookmark(name: "Knowledge",  icon: "books.vertical.fill",      relativePath: "brain/knowledge"),
        ForgeBookmark(name: "Briefings",  icon: "newspaper.fill",           relativePath: "briefings"),
    ]

    // MARK: - Internals

    private let fm = FileManager.default
    let cortanaDir: URL
    private var dirWatchers: [DispatchSourceFileSystemObject] = []

    private init() {
        cortanaDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cortana")
        refresh()
    }

    // MARK: - Public API

    /// Full refresh of the root tree
    func refresh() {
        rootNodes = loadChildren(of: cortanaDir)
        wtLog("[ForgeStore] Refreshed root — \(rootNodes.count) items")
    }

    /// URL for a bookmark
    func url(for bookmark: ForgeBookmark) -> URL {
        cortanaDir.appendingPathComponent(bookmark.relativePath)
    }

    /// Load children of a directory node on demand
    func expand(_ node: FileNode) {
        guard node.isDirectory else { return }
        if node.children == nil {
            node.children = loadChildren(of: node.url)
            watchDirectory(node.url)
        }
        node.isExpanded = true
        wtLog("[ForgeStore] Expanded \(node.name) — \(node.children?.count ?? 0) children")
    }

    func collapse(_ node: FileNode) {
        node.isExpanded = false
    }

    /// Select a file and load its content
    func select(_ node: FileNode) {
        selectedURL = node.url
        isEditing = false
        if node.isDirectory {
            selectedContent = nil
        } else {
            loadContent(node.url)
        }
    }

    func select(url: URL) {
        selectedURL = url
        isEditing = false
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            loadContent(url)
        } else {
            selectedContent = nil
        }
    }

    // MARK: - Editing

    func beginEdit() {
        guard let content = selectedContent else { return }
        draftContent = content
        isEditing = true
    }

    func cancelEdit() {
        isEditing = false
        draftContent = selectedContent ?? ""
    }

    func saveEdit() {
        guard let url = selectedURL, isEditing else { return }
        do {
            try draftContent.write(to: url, atomically: true, encoding: .utf8)
            selectedContent = draftContent
            isEditing = false
            wtLog("[ForgeStore] Saved \(url.lastPathComponent)")
        } catch {
            setError("Failed to save: \(error.localizedDescription)")
        }
    }

    // MARK: - CRUD

    func createFile(named name: String, in directory: URL) {
        let dest = directory.appendingPathComponent(name)
        guard !fm.fileExists(atPath: dest.path) else {
            setError("'\(name)' already exists")
            return
        }
        do {
            try "".write(to: dest, atomically: true, encoding: .utf8)
            refreshSubtree(at: directory)
            select(url: dest)
        } catch {
            setError("Failed to create file: \(error.localizedDescription)")
        }
    }

    func createDirectory(named name: String, in directory: URL) {
        let dest = directory.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
            refreshSubtree(at: directory)
        } catch {
            setError("Failed to create folder: \(error.localizedDescription)")
        }
    }

    func rename(url: URL, to newName: String) {
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fm.fileExists(atPath: dest.path) else {
            setError("'\(newName)' already exists")
            return
        }
        do {
            try fm.moveItem(at: url, to: dest)
            if selectedURL == url { select(url: dest) }
            refreshSubtree(at: url.deletingLastPathComponent())
        } catch {
            setError("Failed to rename: \(error.localizedDescription)")
        }
    }

    func trash(url: URL) {
        do {
            try fm.trashItem(at: url, resultingItemURL: nil)
            if selectedURL == url {
                selectedURL = nil
                selectedContent = nil
            }
            refreshSubtree(at: url.deletingLastPathComponent())
            wtLog("[ForgeStore] Trashed \(url.lastPathComponent)")
        } catch {
            setError("Failed to delete: \(error.localizedDescription)")
        }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }

    // MARK: - Internals

    private func loadContent(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            selectedContent = nil
            return
        }
        selectedContent = content
    }

    func loadChildren(of directory: URL) -> [FileNode] {
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var nodes = contents.compactMap { url -> FileNode? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return nil }
            let isDir = values.isDirectory ?? false
            return FileNode(url: url, isDirectory: isDir)
        }

        // Directories first, then alphabetical
        nodes.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        return nodes
    }

    private func watchDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd != -1 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        let watchedPath = url
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshSubtree(at: watchedPath)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatchers.append(source)
    }

    func refreshSubtree(at directory: URL) {
        let dirPath = directory.path
        if dirPath == cortanaDir.path {
            rootNodes = loadChildren(of: cortanaDir)
            return
        }
        refreshNodes(&rootNodes, targetPath: dirPath)
    }

    private func refreshNodes(_ nodes: inout [FileNode], targetPath: String) {
        for node in nodes {
            guard node.isDirectory else { continue }
            if node.url.path == targetPath, node.children != nil {
                node.children = loadChildren(of: node.url)
                return
            }
            if var children = node.children {
                refreshNodes(&children, targetPath: targetPath)
                node.children = children
            }
        }
    }

    private func setError(_ message: String) {
        errorMessage = message
        showError = true
        wtLog("[ForgeStore] Error: \(message)")
    }

    /// Expand all directory nodes along the path to `target`, then select it.
    func navigate(to target: URL) {
        expandPath(to: target, in: rootNodes)
        select(url: target)
    }

    private func expandPath(to target: URL, in nodes: [FileNode]) {
        let targetPath = target.path
        for node in nodes {
            guard node.isDirectory else { continue }
            let nodePath = node.url.path
            if targetPath.hasPrefix(nodePath + "/") || targetPath == nodePath {
                expand(node)
                if let children = node.children {
                    expandPath(to: target, in: children)
                }
            }
        }
    }

    func stopWatching() {
        for source in dirWatchers { source.cancel() }
        dirWatchers.removeAll()
    }
}
