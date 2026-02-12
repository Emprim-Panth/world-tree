import Foundation

// MARK: - Tool Guard (Security Gate)

/// Pre-flight security gate that intercepts dangerous tool inputs before execution.
/// Pattern-matches on tool names and input patterns to flag destructive operations.
enum ToolGuard {

    /// Risk level for a tool invocation.
    enum RiskLevel: Comparable {
        case safe           // Normal operation
        case caution        // Unusual but not destructive
        case destructive    // Could cause data loss
        case critical       // System-level danger (rm -rf, force push)
    }

    /// Assessment result with details.
    struct Assessment {
        let riskLevel: RiskLevel
        let reason: String
        let toolName: String
        let requiresApproval: Bool

        static func safe(tool: String) -> Assessment {
            Assessment(riskLevel: .safe, reason: "", toolName: tool, requiresApproval: false)
        }
    }

    // MARK: - Dangerous Patterns

    /// Bash command patterns that require human approval
    private static let destructiveBashPatterns: [(pattern: String, reason: String, level: RiskLevel)] = [
        ("rm -rf", "Recursive force delete", .critical),
        ("rm -r -f", "Recursive force delete", .critical),
        ("rm -fr", "Recursive force delete", .critical),
        ("rm --recursive --force", "Recursive force delete", .critical),
        ("rm -r /", "Recursive delete from root", .critical),
        ("sudo rm", "Elevated delete operation", .critical),
        ("git push --force", "Force push (overwrites remote history)", .critical),
        ("git push -f", "Force push (overwrites remote history)", .critical),
        ("git push origin --force", "Force push (overwrites remote history)", .critical),
        ("--force-with-lease", "Force push with lease", .destructive),
        ("git reset --hard", "Hard reset (discards uncommitted changes)", .destructive),
        ("git clean -f", "Force clean (deletes untracked files)", .destructive),
        ("git clean --force", "Force clean (deletes untracked files)", .destructive),
        ("DROP TABLE", "SQL table drop", .critical),
        ("DROP DATABASE", "SQL database drop", .critical),
        ("truncate", "SQL table truncation", .destructive),
        ("chmod 777", "World-writable permissions", .destructive),
        ("chmod -R", "Recursive permission change", .caution),
        (":> /", "File truncation (redirect)", .destructive),
        ("mkfs", "Filesystem formatting", .critical),
        ("dd if=", "Low-level disk write", .critical),
        ("kill -9", "Force kill process", .caution),
        ("pkill", "Process pattern kill", .caution),
        ("launchctl unload", "Service removal", .caution),
    ]

    /// File paths that should trigger extra caution (expanded at runtime)
    private static var protectedPaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/etc/", "/usr/", "/System/", "/Library/",
            "\(home)/.ssh/", "\(home)/.gnupg/", "\(home)/.aws/",
            ".env", "credentials", "secrets",
            "id_rsa", "id_ed25519",
        ]
    }

    // MARK: - Assessment

    /// Assess the risk of a tool invocation.
    static func assess(toolName: String, input: [String: Any]) -> Assessment {
        switch toolName {
        case "bash":
            return assessBash(input)
        case "write_file", "edit_file":
            return assessFileWrite(toolName: toolName, input: input)
        default:
            return .safe(tool: toolName)
        }
    }

    /// Assess a bash command for dangerous patterns.
    private static func assessBash(_ input: [String: Any]) -> Assessment {
        guard let command = input["command"] as? String else {
            return .safe(tool: "bash")
        }

        // Normalize whitespace for pattern matching (defeats "rm  -rf" bypass)
        let lowered = command.lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        for (pattern, reason, level) in destructiveBashPatterns {
            if lowered.contains(pattern.lowercased()) {
                return Assessment(
                    riskLevel: level,
                    reason: reason,
                    toolName: "bash",
                    requiresApproval: level >= .destructive
                )
            }
        }

        // Check for protected path access (case-insensitive on macOS)
        for path in protectedPaths {
            if lowered.contains(path.lowercased()) {
                return Assessment(
                    riskLevel: .caution,
                    reason: "Accesses protected path: \(path)",
                    toolName: "bash",
                    requiresApproval: false
                )
            }
        }

        return .safe(tool: "bash")
    }

    /// Assess file write operations for dangerous targets.
    private static func assessFileWrite(toolName: String, input: [String: Any]) -> Assessment {
        guard let path = input["path"] as? String ?? input["file_path"] as? String else {
            return .safe(tool: toolName)
        }

        // Check protected paths
        for protectedPath in protectedPaths {
            if path.contains(protectedPath) {
                return Assessment(
                    riskLevel: .destructive,
                    reason: "Writing to protected path: \(path)",
                    toolName: toolName,
                    requiresApproval: true
                )
            }
        }

        // Large file overwrites
        let fm = FileManager.default
        if fm.fileExists(atPath: path),
           let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? UInt64,
           size > 1_000_000 {
            return Assessment(
                riskLevel: .caution,
                reason: "Overwriting large file (\(size / 1024)KB)",
                toolName: toolName,
                requiresApproval: false
            )
        }

        return .safe(tool: toolName)
    }
}
