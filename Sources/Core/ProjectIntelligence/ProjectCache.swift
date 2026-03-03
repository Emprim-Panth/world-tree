import Foundation
import GRDB

/// Cache for project data with database persistence
@MainActor
final class ProjectCache {
    
    /// Get all cached projects
    func getAll() throws -> [CachedProject] {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }
        
        return try dbPool.read { db in
            try CachedProject
                .order(Column("last_modified").desc)
                .fetchAll(db)
        }
    }
    
    /// Get a project by name (case-insensitive) — used for sidebar project group lookup
    func getByName(_ name: String) throws -> CachedProject? {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }
        return try dbPool.read { db in
            try CachedProject
                .filter(sql: "lower(name) = lower(?)", arguments: [name])
                .fetchOne(db)
        }
    }

    /// Get a project by path
    func get(path: String) throws -> CachedProject? {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }
        
        return try dbPool.read { db in
            try CachedProject
                .filter(Column("path") == path)
                .fetchOne(db)
        }
    }
    
    /// Update cache with discovered projects
    /// Returns the number of projects updated/inserted
    func update(with projects: [DiscoveredProject]) throws -> Int {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }

        // Read READMEs BEFORE entering the DB transaction — file I/O shouldn't hold the write lock
        let scannedAt = Date()
        let projectsWithReadme: [(DiscoveredProject, String?)] = projects.map { project in
            (project, readREADME(at: project.path))
        }

        var count = 0

        try dbPool.write { db in
            for (project, readme) in projectsWithReadme {
                let cached = CachedProject(from: project, scannedAt: scannedAt, readme: readme)

                // Check if project already exists
                if let existing = try CachedProject.filter(Column("path") == cached.path).fetchOne(db) {
                    // Update existing
                    var updated = cached
                    updated.id = existing.id
                    try updated.update(db)
                } else {
                    // Insert new
                    try cached.insert(db)
                }
                count += 1
            }
        }

        wtLog("[ProjectCache] Updated \(count) projects")
        return count
    }
    
    /// Delete projects that no longer exist on disk
    func prune() throws -> Int {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }
        
        let fileManager = FileManager.default
        var deletedCount = 0
        
        let cached = try getAll()
        
        for project in cached {
            if !fileManager.fileExists(atPath: project.path) {
                _ = try dbPool.write { db in
                    try project.delete(db)
                }
                deletedCount += 1
            }
        }
        
        if deletedCount > 0 {
            wtLog("[ProjectCache] Pruned \(deletedCount) stale projects")
        }
        
        return deletedCount
    }
    
    /// Invalidate (delete) a specific project from cache
    func invalidate(path: String) throws {
        guard let dbPool = DatabaseManager.shared.dbPool else {
            throw ProjectCacheError.databaseNotInitialized
        }
        
        _ = try dbPool.write { db in
            try CachedProject
                .filter(Column("path") == path)
                .deleteAll(db)
        }
    }
    
    /// Read README.md from project directory
    private func readREADME(at path: String) -> String? {
        let readmePath = (path as NSString).appendingPathComponent("README.md")
        guard FileManager.default.fileExists(atPath: readmePath) else {
            return nil
        }
        
        guard let content = try? String(contentsOfFile: readmePath, encoding: .utf8) else {
            return nil
        }
        
        // Limit to first 2000 characters to avoid bloating cache
        return String(content.prefix(2000))
    }
}

// MARK: - Errors

enum ProjectCacheError: Error, LocalizedError {
    case databaseNotInitialized
    
    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Database not initialized"
        }
    }
}
