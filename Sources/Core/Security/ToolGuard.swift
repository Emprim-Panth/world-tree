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
        ("dd of=", "Low-level disk write (output)", .critical),
        ("chmod 0777", "World-writable permissions", .destructive),
        ("chmod 7777", "World-writable permissions (sticky/suid)", .destructive),
        ("| bash", "Pipe to bash shell (potential code injection)", .critical),
        ("| sh", "Pipe to sh shell (potential code injection)", .critical),
        ("| eval", "Pipe to eval (potential code injection)", .critical),
        ("base64 -d", "Base64 decode (common obfuscation technique)", .destructive),
        ("git config core.hookspath", "Git hook path override (enables arbitrary code execution)", .critical),
        ("git config core.fsmonitor", "Git fsmonitor hook (enables arbitrary code execution)", .critical),
        (":> /etc", "File truncation in system paths", .destructive),
        (":> /usr", "File truncation in system paths", .destructive),
        (":> ~/.ssh", "File truncation in SSH directory", .destructive),
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

        // Normalize for pattern matching:
        // - Lowercase for case-insensitive matching
        // - Strip quotes so "rm" "-rf" still matches (quote bypass)
        // - Split on ANY whitespace (tabs, newlines) not just spaces (whitespace bypass)
        let lowered = command.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split { $0.isWhitespace }
            .joined(separator: " ")

        // Reject command substitution — enables encoded/obfuscated destructive commands
        if command.contains("$(") || command.contains("`") {
            return Assessment(
                riskLevel: .destructive,
                reason: "Command uses shell substitution (potential obfuscation)",
                toolName: "bash",
                requiresApproval: true
            )
        }

        // Flag variable expansion — $VAR can alias to dangerous commands at runtime.
        // We allow common safe env vars ($HOME, $PATH, $USER, $PWD, etc.)
        // but flag unknown variables. This catches: ALIAS="rm -rf"; $ALIAS /
        let knownSafeVars: Set<String> = ["home", "path", "user", "pwd", "shell", "term", "lang", "tmpdir"]
        if command.contains("$") {
            // Extract all variable names used (e.g. "$FOO" → "foo")
            let parts = command.lowercased().components(separatedBy: "$").dropFirst()
            let hasUnknownVar = parts.contains { segment in
                let varName = String(segment.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
                return !varName.isEmpty && !knownSafeVars.contains(varName)
            }
            if hasUnknownVar {
                return Assessment(
                    riskLevel: .caution,
                    reason: "Command uses shell variable expansion — verify no variable aliases a dangerous command",
                    toolName: "bash",
                    requiresApproval: false
                )
            }
        }

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
