import Foundation
import AppKit

/// Handles file-level operations on projects: rename, delete, archive, reveal.
@MainActor
final class ProjectFileManager {
    static let shared = ProjectFileManager()

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser

    private var developmentDir: URL { home.appendingPathComponent("Development") }
    private var archivesDir: URL { home.appendingPathComponent("Development/Archives") }

    private init() {}

    /// Full path URL for a project name.
    func projectURL(for project: String, path: String?) -> URL {
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return developmentDir.appendingPathComponent(project)
    }

    // MARK: - Reveal in Finder

    func revealInFinder(project: String, path: String?) {
        let url = projectURL(for: project, path: path)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: - Rename

    enum ProjectFileError: LocalizedError {
        case notFound(String)
        case alreadyExists(String)
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let msg): return msg
            case .alreadyExists(let msg): return msg
            case .operationFailed(let msg): return msg
            }
        }
    }

    /// Renames a project directory. Returns the new path.
    @discardableResult
    func rename(project: String, path: String?, to newName: String) throws -> URL {
        let source = projectURL(for: project, path: path)
        guard fm.fileExists(atPath: source.path) else {
            throw ProjectFileError.notFound("Project directory not found: \(source.path)")
        }

        let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fm.fileExists(atPath: dest.path) else {
            throw ProjectFileError.alreadyExists("A directory named '\(newName)' already exists")
        }

        try fm.moveItem(at: source, to: dest)

        // Update compass.db path if possible
        CompassStore.shared.updatePath(dest.path, for: project, newName: newName)
        wtLog("[ProjectFileManager] Renamed \(project) → \(newName)")
        return dest
    }

    // MARK: - Archive

    /// Moves a project to ~/Development/Archives/
    func archive(project: String, path: String?) throws {
        let source = projectURL(for: project, path: path)
        guard fm.fileExists(atPath: source.path) else {
            throw ProjectFileError.notFound("Project directory not found: \(source.path)")
        }

        try fm.createDirectory(at: archivesDir, withIntermediateDirectories: true)

        let dest = archivesDir.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            // Append timestamp to avoid collision
            let ts = Int(Date().timeIntervalSince1970)
            let destTS = archivesDir.appendingPathComponent("\(source.lastPathComponent)-\(ts)")
            try fm.moveItem(at: source, to: destTS)
        } else {
            try fm.moveItem(at: source, to: dest)
        }

        wtLog("[ProjectFileManager] Archived \(project) → Archives/")
    }

    // MARK: - Delete

    /// Moves a project to Trash (recoverable).
    func trash(project: String, path: String?) throws {
        let source = projectURL(for: project, path: path)
        guard fm.fileExists(atPath: source.path) else {
            throw ProjectFileError.notFound("Project directory not found: \(source.path)")
        }

        try fm.trashItem(at: source, resultingItemURL: nil)
        wtLog("[ProjectFileManager] Trashed \(project)")
    }
}
