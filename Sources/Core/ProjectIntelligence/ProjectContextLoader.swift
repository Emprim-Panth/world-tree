import Foundation

/// Loads rich context for a project to inject into Claude prompts
final class ProjectContextLoader {
    private let fileManager = FileManager.default
    
    /// Load full context for a project
    func loadContext(for project: CachedProject) async -> ProjectContext {
        let recentCommits = await loadRecentCommits(at: project.path)
        let directoryStructure = loadDirectoryStructure(at: project.path)
        
        return ProjectContext(
            project: project,
            recentCommits: recentCommits,
            directoryStructure: directoryStructure
        )
    }
    
    /// Load recent commit messages via git log
    private func loadRecentCommits(at path: String) async -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["log", "-10", "--pretty=format:%h %s"]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else { return [] }
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            
            return output
                .split(separator: "\n")
                .map { String($0) }
        } catch {
            return []
        }
    }
    
    /// Generate a simplified directory tree (max depth 2, key files only)
    private func loadDirectoryStructure(at path: String) -> String {
        var output: [String] = []
        
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return ""
        }
        
        let sorted = contents.sorted()
        let excluded: Set<String> = ["node_modules", ".git", "DerivedData", "build", "dist", "target", ".build", "Pods"]
        
        for item in sorted {
            guard !excluded.contains(item), !item.hasPrefix(".") else { continue }
            
            let itemPath = (path as NSString).appendingPathComponent(item)
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory)
            
            if isDirectory.boolValue {
                output.append("📁 \(item)/")
                
                // Add key files from subdirectory (depth 1)
                if let subContents = try? fileManager.contentsOfDirectory(atPath: itemPath) {
                    let keyFiles = subContents
                        .filter { isKeyFile($0) }
                        .sorted()
                        .prefix(5)
                    
                    for file in keyFiles {
                        output.append("  📄 \(file)")
                    }
                }
            } else if isKeyFile(item) {
                output.append("📄 \(item)")
            }
        }
        
        return output.prefix(30).joined(separator: "\n")
    }
    
    /// Check if a file is "key" (worth showing in structure)
    private func isKeyFile(_ name: String) -> Bool {
        let keyNames = ["README", "LICENSE", "Cargo.toml", "Package.swift", "package.json", "tsconfig.json", "pyproject.toml", "go.mod", "Makefile"]
        let keyExtensions = [".swift", ".rs", ".ts", ".tsx", ".py", ".go", ".md", ".yml", ".yaml", ".json"]
        
        // Check exact names
        if keyNames.contains(where: { name.hasPrefix($0) }) {
            return true
        }
        
        // Check extensions
        return keyExtensions.contains(where: { name.hasSuffix($0) })
    }
}
