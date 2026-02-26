import Foundation

/// Scans ~/Development for projects and detects their type
final class ProjectScanner {
    private let fileManager = FileManager.default
    private let excludedDirs: Set<String> = [
        // Build artifacts & package dirs
        "node_modules", ".git", "DerivedData", "build", "dist", "target", ".build", "Pods",
        // Archived projects — not actively developed
        "Argus", "PDT-Mail", "SpecterDC", "TicketMaster", "Visual-Swift",
        "MountOlympus", "OpenClaude-Reference", "ComfyUI", "HybridAI", "fish-speech",
        // Manually hidden — removed from scanner, archive via World Tree when ready
        "ark-gateway", "ark-terminals", "ark-tacpad", "ark-field-mode", "the-cartographer",
        "CortanaCanvas", "cortana-core", "cortana-core-python-legacy",
        // Non-project directories
        "Archives", "docs", "agent-knowledge-base", "Game-Dev-Team-Knowledge"
    ]
    
    /// Scan ~/Development and return all discovered projects
    func scanDevelopmentDirectory() async throws -> [DiscoveredProject] {
        let devPath = resolveDevDirectory()

        guard fileManager.fileExists(atPath: devPath) else {
            throw ProjectScanError.developmentDirectoryNotFound
        }
        
        wtLog("[ProjectScanner] Starting scan of \(devPath)")
        
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
        
        wtLog("[ProjectScanner] Found \(projects.count) projects")
        return projects
    }
    
    /// Resolve the development directory to scan.
    /// Priority: UserDefaults override → ~/Documents/Development → ~/Development
    private func resolveDevDirectory() -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if let override = UserDefaults.standard.string(forKey: "developmentDirectory"),
           !override.isEmpty,
           fileManager.fileExists(atPath: override) {
            return override
        }
        let docsDev = "\(home)/Documents/Development"
        if fileManager.fileExists(atPath: docsDev) { return docsDev }
        return "\(home)/Development"
    }

    /// Detect if a directory is a project and determine its type.
    /// Any directory with a .git folder is included even if the specific type is unrecognized.
    private func detectProject(at path: String, name: String) throws -> DiscoveredProject? {
        let type = detectProjectType(at: path)
        let isGit = fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
        guard type != .unknown || isGit else { return nil }
        
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
    
    /// Run a git command and return stdout.
    /// Uses readabilityHandler + terminationHandler to avoid blocking cooperative threads
    /// and prevent pipe buffer deadlocks.
    private func runGitCommand(at path: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice  // Discard stderr to /dev/null

        // Drain stdout incrementally to avoid pipe buffer deadlock
        let accum = PipeAccumulator()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                pipe.fileHandleForReading.readabilityHandler = nil
            } else {
                accum.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        // Use a semaphore with short timeout — this runs on a GCD utility queue
        // (via Task.detached in the caller), NOT on the cooperative thread pool.
        let sem = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sem.signal() }
        if sem.wait(timeout: .now() + .seconds(10)) == .timedOut {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = accum.data
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
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
