import Foundation

/// Scans ~/Development for projects and detects their type
final class ProjectScanner {
    private let fileManager = FileManager.default
    private let excludedDirs: Set<String> = [
        "node_modules",
        ".git",
        "DerivedData",
        "build",
        "dist",
        "target",
        ".build",
        "Pods"
    ]
    
    /// Scan ~/Development and return all discovered projects
    func scanDevelopmentDirectory() async throws -> [DiscoveredProject] {
        let devPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Development")
            .path
        
        guard fileManager.fileExists(atPath: devPath) else {
            throw ProjectScanError.developmentDirectoryNotFound
        }
        
        canvasLog("[ProjectScanner] Starting scan of \(devPath)")
        
        let contents = try fileManager.contentsOfDirectory(atPath: devPath)
        var projects: [DiscoveredProject] = []
        
        for item in contents {
            let itemPath = (devPath as NSString).appendingPathComponent(item)
            var isDirectory: ObjCBool = false
            
            guard fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !item.hasPrefix("."),
                  !excludedDirs.contains(item) else {
                continue
            }
            
            if let project = try detectProject(at: itemPath, name: item) {
                projects.append(project)
            }
        }
        
        canvasLog("[ProjectScanner] Found \(projects.count) projects")
        return projects
    }
    
    /// Detect if a directory is a project and determine its type
    private func detectProject(at path: String, name: String) throws -> DiscoveredProject? {
        let type = detectProjectType(at: path)
        guard type != .unknown else { return nil }
        
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let lastModified = (attributes[.modificationDate] as? Date) ?? Date()
        
        let gitStatus = detectGitStatus(at: path)
        
        return DiscoveredProject(
            path: path,
            name: name,
            type: type,
            lastModified: lastModified,
            gitStatus: gitStatus
        )
    }
    
    /// Detect project type based on marker files
    private func detectProjectType(at path: String) -> ProjectType {
        // Swift: .xcodeproj, .xcworkspace, or Package.swift
        if hasFile(at: path, matching: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return .swift
        }
        if hasFile(at: path, named: "Package.swift") {
            return .swift
        }
        
        // Rust: Cargo.toml
        if hasFile(at: path, named: "Cargo.toml") {
            return .rust
        }
        
        // TypeScript: package.json + tsconfig.json
        if hasFile(at: path, named: "package.json") && hasFile(at: path, named: "tsconfig.json") {
            return .typescript
        }
        
        // Python: pyproject.toml or setup.py
        if hasFile(at: path, named: "pyproject.toml") || hasFile(at: path, named: "setup.py") {
            return .python
        }
        
        // Go: go.mod
        if hasFile(at: path, named: "go.mod") {
            return .go
        }
        
        // Web: index.html + package.json (no tsconfig)
        if hasFile(at: path, named: "index.html") && hasFile(at: path, named: "package.json") {
            return .web
        }
        
        return .unknown
    }
    
    /// Check if a file exists in the directory
    private func hasFile(at path: String, named fileName: String) -> Bool {
        let filePath = (path as NSString).appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: filePath)
    }
    
    /// Check if directory contains a file matching predicate
    private func hasFile(at path: String, matching predicate: (String) -> Bool) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return false
        }
        return contents.contains(where: predicate)
    }
    
    /// Detect git status (branch, dirty state, last commit)
    private func detectGitStatus(at path: String) -> GitStatus? {
        let gitPath = (path as NSString).appendingPathComponent(".git")
        guard fileManager.fileExists(atPath: gitPath) else {
            return nil
        }
        
        // Get current branch
        let branch = runGitCommand(at: path, args: ["rev-parse", "--abbrev-ref", "HEAD"])
        
        // Check if dirty
        let status = runGitCommand(at: path, args: ["status", "--porcelain"])
        let isDirty = !(status?.isEmpty ?? true)
        
        // Get last commit message
        let lastCommit = runGitCommand(at: path, args: ["log", "-1", "--pretty=%s"])
        
        // Get last commit date
        let lastCommitDateStr = runGitCommand(at: path, args: ["log", "-1", "--pretty=%ct"])
        let lastCommitDate = lastCommitDateStr.flatMap { str -> Date? in
            guard let timestamp = TimeInterval(str.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return Date(timeIntervalSince1970: timestamp)
        }
        
        return GitStatus(
            branch: branch,
            isDirty: isDirty,
            lastCommitMessage: lastCommit,
            lastCommitDate: lastCommitDate
        )
    }
    
    /// Run a git command and return stdout
    private func runGitCommand(at path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return nil }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }
}

// MARK: - Errors

enum ProjectScanError: Error, LocalizedError {
    case developmentDirectoryNotFound
    
    var errorDescription: String? {
        switch self {
        case .developmentDirectoryNotFound:
            return "~/Development directory not found"
        }
    }
}
