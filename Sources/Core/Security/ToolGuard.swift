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

    // MARK: - Path Canonicalization

    /// Canonicalize a file path to prevent traversal attacks.
    /// Resolves `..`, `.`, `~`, and symlinks to produce an absolute path.
    /// Returns nil if the path contains null bytes (string truncation attack).
    private static func canonicalizePath(_ path: String) -> String? {
        // Reject null bytes — can truncate strings in C-based APIs
        guard !path.contains("\0") else { return nil }

        // Expand ~ to home directory, resolve . and .. components
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardized
        return url.path
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

    /// Extract the text content inside $(...), `...`, <(...), >(...) from a command.
    /// Used to scan inner commands without blocking the outer command based on substitution syntax alone.
    private static func extractSubstitutionContents(_ command: String) -> String {
        var result = ""
        var i = command.startIndex
        while i < command.endIndex {
            let c = command[i]
            // $( ... ) or ${ ... }
            if c == "$" {
                let next = command.index(after: i)
                if next < command.endIndex {
                    let n = command[next]
                    if n == "(" || n == "{" {
                        let close: Character = n == "(" ? ")" : "}"
                        var depth = 1
                        var j = command.index(after: next)
                        while j < command.endIndex && depth > 0 {
                            if command[j] == n { depth += 1 }
                            else if command[j] == close { depth -= 1 }
                            j = command.index(after: j)
                        }
                        result += command[next..<j] + " "
                    }
                }
            }
            // backtick `...`
            if c == "`" {
                var j = command.index(after: i)
                while j < command.endIndex && command[j] != "`" {
                    j = command.index(after: j)
                }
                if j < command.endIndex {
                    result += command[i..<j] + " "
                }
            }
            i = command.index(after: i)
        }
        return result
    }

    /// Assess a bash command for dangerous patterns.
    private static func assessBash(_ input: [String: Any]) -> Assessment {
        guard let command = input["command"] as? String else {
            return .safe(tool: "bash")
        }

        // Reject null bytes early — can truncate strings in C-based APIs
        if command.contains("\0") {
            return Assessment(
                riskLevel: .critical,
                reason: "Command contains null bytes (string truncation attack)",
                toolName: "bash",
                requiresApproval: true
            )
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

        // Flag command substitution only when the inner command itself is dangerous.
        // Blanket rejection of $() broke virtually every Claude bash tool call since
        // subshell substitution is ubiquitous in normal shell scripting (date, wc, find, etc.)
        // Instead: scan the content inside $(...) and backticks for dangerous sub-commands.
        let dangerousSubshellPatterns = ["rm ", "rm\t", "rm\n", "sudo ", "curl |", "wget |", "mkfs", "dd if=", "dd of="]
        // Extract $(...) contents and check for dangerous inner commands
        if command.contains("$(") || command.contains("`") {
            let substitutionContent = extractSubstitutionContents(command)
            let lowerSub = substitutionContent.lowercased()
            for pattern in dangerousSubshellPatterns {
                if lowerSub.contains(pattern) {
                    return Assessment(
                        riskLevel: .critical,
                        reason: "Command substitution contains dangerous inner command: \(pattern.trimmingCharacters(in: .whitespaces))",
                        toolName: "bash",
                        requiresApproval: true
                    )
                }
            }
            // Substitution present but inner content is safe — log for visibility, don't block
        }

        // Reject process substitution only when combined with dangerous patterns
        // diff <(cmd1) <(cmd2) is normal; restrict to cases where inner content is dangerous
        if command.contains("<(") || command.contains(">(") {
            let substitutionContent = extractSubstitutionContents(command)
            let lowerSub = substitutionContent.lowercased()
            for pattern in dangerousSubshellPatterns {
                if lowerSub.contains(pattern) {
                    return Assessment(
                        riskLevel: .destructive,
                        reason: "Process substitution contains dangerous inner command: \(pattern.trimmingCharacters(in: .whitespaces))",
                        toolName: "bash",
                        requiresApproval: true
                    )
                }
            }
        }

        // Reject dangerous parameter expansion — ${...} containing command execution patterns
        // Allow ${var//pattern/replacement} (common string substitution) — only flag ${ with
        // embedded command substitution $( or backtick inside the expansion.
        if command.contains("${") {
            let dangerousExpansionPatterns = ["$(", "`"]
            let parts = command.components(separatedBy: "${").dropFirst()
            for part in parts {
                if let closeBrace = part.firstIndex(of: "}") {
                    let inner = String(part[part.startIndex..<closeBrace])
                    for pattern in dangerousExpansionPatterns {
                        if inner.contains(pattern) {
                            return Assessment(
                                riskLevel: .destructive,
                                reason: "Command uses dangerous parameter expansion (embedded command execution via ${\(inner)})",
                                toolName: "bash",
                                requiresApproval: true
                            )
                        }
                    }
                }
            }
        }

        // Reject ANSI-C hex quoting — $'\x72\x6d' can encode "rm" etc.
        if lowered.contains("$'\\x") || lowered.contains("$\"\\x") {
            return Assessment(
                riskLevel: .destructive,
                reason: "Command uses ANSI-C hex quoting (potential obfuscation)",
                toolName: "bash",
                requiresApproval: true
            )
        }

        // Reject here-strings/heredocs containing destructive commands
        if lowered.contains("<<<") || lowered.contains("<<") {
            let destructiveKeywords = ["rm ", "rm\t", "chmod ", "kill ", "mkfs", "dd ", "sudo "]
            for keyword in destructiveKeywords {
                if lowered.contains(keyword) {
                    return Assessment(
                        riskLevel: .destructive,
                        reason: "Here-string/heredoc may pipe destructive command (\(keyword.trimmingCharacters(in: .whitespaces)))",
                        toolName: "bash",
                        requiresApproval: true
                    )
                }
            }
        }

        // Expand backslash-escaped command names before pattern matching (e.g. r\m → rm)
        let deobfuscated = lowered.replacingOccurrences(of: "\\", with: "")

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
            let lowerPattern = pattern.lowercased()
            if lowered.contains(lowerPattern) || deobfuscated.contains(lowerPattern) {
                return Assessment(
                    riskLevel: level,
                    reason: reason,
                    toolName: "bash",
                    requiresApproval: level >= .destructive
                )
            }
        }

        // Check for protected path access (case-insensitive on macOS)
        // Also canonicalize any path-like tokens to catch traversal attacks
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

        // Canonicalize path-like arguments to catch traversal (e.g. /safe/../etc/passwd)
        let tokens = command.components(separatedBy: .whitespaces)
        for token in tokens where token.contains("..") || token.contains("~") {
            if let resolved = canonicalizePath(token) {
                let lowerResolved = resolved.lowercased()
                for path in protectedPaths {
                    if lowerResolved.contains(path.lowercased()) {
                        return Assessment(
                            riskLevel: .destructive,
                            reason: "Path traversal to protected path: \(token) → \(resolved)",
                            toolName: "bash",
                            requiresApproval: true
                        )
                    }
                }
            }
        }

        return .safe(tool: "bash")
    }

    /// Assess file write operations for dangerous targets.
    private static func assessFileWrite(toolName: String, input: [String: Any]) -> Assessment {
        guard let rawPath = input["path"] as? String ?? input["file_path"] as? String else {
            return .safe(tool: toolName)
        }

        // Canonicalize path FIRST to prevent traversal attacks (e.g. ../../etc/passwd)
        guard let path = canonicalizePath(rawPath) else {
            return Assessment(
                riskLevel: .critical,
                reason: "Path contains null bytes (string truncation attack): \(rawPath)",
                toolName: toolName,
                requiresApproval: true
            )
        }

        // Check protected paths (case-insensitive — macOS filesystem is case-insensitive)
        let lowerPath = path.lowercased()
        for protectedPath in protectedPaths {
            if lowerPath.contains(protectedPath.lowercased()) {
                return Assessment(
                    riskLevel: .destructive,
                    reason: "Writing to protected path: \(path)",
                    toolName: toolName,
                    requiresApproval: true
                )
            }
        }

        // Reject writes outside user's home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !path.hasPrefix(home) && !path.hasPrefix("/tmp/") && !path.hasPrefix("/var/folders/") {
            return Assessment(
                riskLevel: .destructive,
                reason: "Write target outside home directory: \(path)",
                toolName: toolName,
                requiresApproval: true
            )
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
