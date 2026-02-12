import Foundation
import GRDB

// MARK: - Project Type Detection

enum ProjectType: String, Codable, DatabaseValueConvertible {
    case swift
    case rust
    case typescript
    case python
    case go
    case web
    case unknown
    
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .rust: return "Rust"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .go: return "Go"
        case .web: return "Web"
        case .unknown: return "Unknown"
        }
    }
    
    var icon: String {
        switch self {
        case .swift: return "swift"
        case .rust: return "gearshape.2"
        case .typescript: return "chevron.left.forwardslash.chevron.right"
        case .python: return "terminal"
        case .go: return "goforward"
        case .web: return "globe"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Git Status

struct GitStatus: Codable, Equatable {
    let branch: String?
    let isDirty: Bool
    let lastCommitMessage: String?
    let lastCommitDate: Date?
    
    init(branch: String?, isDirty: Bool, lastCommitMessage: String? = nil, lastCommitDate: Date? = nil) {
        self.branch = branch
        self.isDirty = isDirty
        self.lastCommitMessage = lastCommitMessage
        self.lastCommitDate = lastCommitDate
    }
}

// MARK: - Discovered Project (from filesystem scan)

struct DiscoveredProject: Equatable {
    let path: String
    let name: String
    let type: ProjectType
    let lastModified: Date
    let gitStatus: GitStatus?
    
    var isGitRepo: Bool {
        gitStatus != nil
    }
}

// MARK: - Cached Project (stored in database)

struct CachedProject: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "project_cache"
    
    var id: Int?
    let path: String
    let name: String
    let type: ProjectType
    let gitBranch: String?
    let gitDirty: Bool
    let lastModified: Date
    let lastScanned: Date
    let readme: String?
    
    init(
        id: Int? = nil,
        path: String,
        name: String,
        type: ProjectType,
        gitBranch: String?,
        gitDirty: Bool,
        lastModified: Date,
        lastScanned: Date,
        readme: String? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.type = type
        self.gitBranch = gitBranch
        self.gitDirty = gitDirty
        self.lastModified = lastModified
        self.lastScanned = lastScanned
        self.readme = readme
    }
    
    init(from discovered: DiscoveredProject, scannedAt: Date = Date(), readme: String? = nil) {
        self.id = nil
        self.path = discovered.path
        self.name = discovered.name
        self.type = discovered.type
        self.gitBranch = discovered.gitStatus?.branch
        self.gitDirty = discovered.gitStatus?.isDirty ?? false
        self.lastModified = discovered.lastModified
        self.lastScanned = scannedAt
        self.readme = readme
    }
}

// MARK: - Project Context (for Claude injection)

struct ProjectContext {
    let project: CachedProject
    let recentCommits: [String]
    let directoryStructure: String
    
    /// Format as markdown for Claude system prompt
    func formatForClaude() -> String {
        var output = """
        # Project Context: \(project.name)
        
        **Type:** \(project.type.displayName)
        **Path:** `\(project.path)`
        """
        
        if let branch = project.gitBranch {
            output += "\n**Git Branch:** `\(branch)`"
            if project.gitDirty {
                output += " (uncommitted changes)"
            }
        }
        
        if let readme = project.readme, !readme.isEmpty {
            output += """
            
            
            ## README
            \(readme)
            """
        }
        
        if !recentCommits.isEmpty {
            output += """
            
            
            ## Recent Commits
            \(recentCommits.prefix(5).joined(separator: "\n"))
            """
        }
        
        if !directoryStructure.isEmpty {
            output += """
            
            
            ## Directory Structure
            ```
            \(directoryStructure)
            ```
            """
        }
        
        return output
    }
}
