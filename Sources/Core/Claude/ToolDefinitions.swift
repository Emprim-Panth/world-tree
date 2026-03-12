import Foundation

/// Static JSON Schema definitions for the tools Canvas gives Claude.
enum WorldTreeTools {

    /// All tool definitions with strict mode and cache optimization.
    /// - Strict mode: guarantees schema-valid tool calls via constrained decoding.
    /// - 1-hour cache: tool definitions are identical across sessions, so the last tool
    ///   carries a 1h cache_control to persist the entire tool block in Anthropic's cache.
    static func definitions() -> [ToolSchema] {
        var tools = [readFile, writeFile, editFile, bash, glob, grep,
                     buildProject, runTests, checkpointCreate, checkpointRevert, checkpointList,
                     backgroundRun, listTerminals, terminalOutput, searchConversation, captureScreenshot,
                     gitStatus, gitLog, gitDiff,
                     findUnusedCode, lintCheck,
                     simulatorList, simulatorBuildRun, simulatorAppManage, simulatorScreenshot]
        // Apply strict mode to all tools — constrained decoding eliminates malformed arguments
        for i in tools.indices {
            tools[i].strict = true
        }
        // Last tool carries 1-hour cache — caches the entire tool definition block across sessions
        tools[tools.count - 1].cacheControl = .ephemeral1h
        return tools
    }

    static let readFile = ToolSchema(
        name: "read_file",
        description: """
            Read a file from the local filesystem. Returns file contents with line numbers. \
            Use this to examine source code, configuration files, or any text file. \
            For large files, use offset and limit to read specific sections.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "file_path": PropertySchema(
                    type: "string",
                    description: "Absolute path to the file to read"
                ),
                "offset": PropertySchema(
                    type: "integer",
                    description: "Line number to start reading from (1-based). Optional."
                ),
                "limit": PropertySchema(
                    type: "integer",
                    description: "Maximum number of lines to read. Optional, defaults to entire file."
                ),
            ],
            required: ["file_path"]
        )
    )

    static let writeFile = ToolSchema(
        name: "write_file",
        description: """
            Write content to a file on the local filesystem. Creates the file if it doesn't exist, \
            creates parent directories as needed, and overwrites existing content. \
            Use this to create new files or completely replace file contents.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "file_path": PropertySchema(
                    type: "string",
                    description: "Absolute path to the file to write"
                ),
                "content": PropertySchema(
                    type: "string",
                    description: "The full content to write to the file"
                ),
            ],
            required: ["file_path", "content"]
        )
    )

    static let editFile = ToolSchema(
        name: "edit_file",
        description: """
            Make a targeted edit to a file by finding an exact string and replacing it. \
            The old_string must match exactly one location in the file (including whitespace and indentation). \
            If it matches zero or more than one location, the edit fails with an error. \
            Use this for surgical modifications without rewriting the entire file.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "file_path": PropertySchema(
                    type: "string",
                    description: "Absolute path to the file to edit"
                ),
                "old_string": PropertySchema(
                    type: "string",
                    description: "The exact string to find (must match exactly once in the file)"
                ),
                "new_string": PropertySchema(
                    type: "string",
                    description: "The replacement string"
                ),
            ],
            required: ["file_path", "old_string", "new_string"]
        )
    )

    static let bash = ToolSchema(
        name: "bash",
        description: """
            Execute a shell command and return stdout and stderr. \
            The command runs in the branch's working directory with the user's environment. \
            Use this for git operations, build commands, running tests, package management, \
            or any terminal operation. Timeout defaults to 120 seconds, max 600.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "command": PropertySchema(
                    type: "string",
                    description: "The shell command to execute"
                ),
                "timeout": PropertySchema(
                    type: "integer",
                    description: "Timeout in seconds. Default 120, max 600."
                ),
            ],
            required: ["command"]
        )
    )

    static let glob = ToolSchema(
        name: "glob",
        description: """
            Find files matching a glob pattern. Returns matching file paths sorted by modification time. \
            Supports patterns like '**/*.swift', 'Sources/**/*.ts', '*.json'. \
            Searches from the specified path or the working directory by default.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "pattern": PropertySchema(
                    type: "string",
                    description: "Glob pattern to match files against (e.g. '**/*.swift')"
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Directory to search in. Defaults to working directory."
                ),
            ],
            required: ["pattern"]
        )
    )

    static let buildProject = ToolSchema(
        name: "build_project",
        description: """
            Build the current project and return structured error/warning results. \
            Auto-detects project type: Xcode (.xcodeproj/Package.swift), Cargo (Cargo.toml), \
            npm (package.json). Optionally specify a scheme for Xcode projects. \
            Returns JSON array of {file, line, column, severity, message}.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "scheme": PropertySchema(
                    type: "string",
                    description: "Xcode scheme name. Auto-detected if not specified."
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    static let runTests = ToolSchema(
        name: "run_tests",
        description: """
            Run tests for the current project and return structured results. \
            Auto-detects project type. Returns JSON array of \
            {test_name, status (pass/fail/skip), duration, failure_message, file, line}.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "scheme": PropertySchema(
                    type: "string",
                    description: "Xcode scheme name. Auto-detected if not specified."
                ),
                "filter": PropertySchema(
                    type: "string",
                    description: "Test name filter (e.g. 'test_login' or 'AuthTests')"
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    static let checkpointCreate = ToolSchema(
        name: "checkpoint_create",
        description: """
            Create a named checkpoint of the current working directory state via git stash. \
            Saves all tracked and untracked files. Use before risky multi-file operations.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "name": PropertySchema(
                    type: "string",
                    description: "Descriptive name for the checkpoint (e.g. 'before refactor')"
                ),
            ],
            required: ["name"]
        )
    )

    static let checkpointRevert = ToolSchema(
        name: "checkpoint_revert",
        description: """
            Revert to a previously created checkpoint. Lists available checkpoints if no index given. \
            Applies the checkpoint without removing it from the stash.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "index": PropertySchema(
                    type: "integer",
                    description: "Stash index to revert to (from checkpoint_list). Defaults to most recent (0)."
                ),
            ],
            required: []
        )
    )

    static let checkpointList = ToolSchema(
        name: "checkpoint_list",
        description: """
            List all canvas checkpoints with their indices, names, and timestamps.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [:],
            required: []
        )
    )

    static let grep = ToolSchema(
        name: "grep",
        description: """
            Search file contents using a regular expression pattern. Returns matching lines \
            with file paths and line numbers. Use for finding code patterns, function definitions, \
            imports, or any text across the codebase.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "pattern": PropertySchema(
                    type: "string",
                    description: "Regex pattern to search for"
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "File or directory to search. Defaults to working directory."
                ),
                "include": PropertySchema(
                    type: "string",
                    description: "Glob to filter files (e.g. '*.swift', '*.ts')"
                ),
                "context": PropertySchema(
                    type: "integer",
                    description: "Number of context lines before and after each match"
                ),
            ],
            required: ["pattern"]
        )
    )

    static let backgroundRun = ToolSchema(
        name: "background_run",
        description: """
            Execute a long-running command in the background. Returns a job ID immediately \
            without waiting for completion. Output is stored in the database and a macOS \
            notification fires when the job completes. Use for builds, test suites, \
            deployments, or any command that takes more than a few seconds.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "command": PropertySchema(
                    type: "string",
                    description: "The shell command to execute in the background"
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Working directory. Defaults to branch working directory."
                ),
            ],
            required: ["command"]
        )
    )

    static let listTerminals = ToolSchema(
        name: "list_terminals",
        description: """
            Discover active terminal sessions. Lists tmux sessions with window/pane info \
            and detects running development processes (xcodebuild, cargo, npm, python, etc.). \
            Use to understand what's currently running on the system.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [:],
            required: []
        )
    )

    static let terminalOutput = ToolSchema(
        name: "terminal_output",
        description: """
            Capture recent output from a tmux pane. Specify the session name \
            (and optionally window:pane). Returns the last N lines of visible output.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "session": PropertySchema(
                    type: "string",
                    description: "tmux session name (from list_terminals)"
                ),
                "pane": PropertySchema(
                    type: "string",
                    description: "Window and pane target (e.g. '0:0.0'). Defaults to active pane."
                ),
                "lines": PropertySchema(
                    type: "integer",
                    description: "Number of lines to capture. Default 50, max 500."
                ),
            ],
            required: ["session"]
        )
    )

    static let searchConversation = ToolSchema(
        name: "search_conversation",
        description: """
            Search this conversation's full message history using BM25 full-text search. \
            Returns the most relevant past messages matching the query. \
            Use this when you need context from earlier in the conversation that isn't \
            in your current context window.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "query": PropertySchema(
                    type: "string",
                    description: "Search terms to find relevant messages"
                ),
                "limit": PropertySchema(
                    type: "integer",
                    description: "Max results (default 10, max 20)"
                ),
            ],
            required: ["query"]
        )
    )

    static let captureScreenshot = ToolSchema(
        name: "capture_screenshot",
        description: """
            Capture a screenshot from the iOS Simulator or the Mac screen. \
            Returns the file path of the saved image.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "target": PropertySchema(
                    type: "string",
                    description: "What to capture: 'simulator' for booted iOS Simulator, 'screen' for the full Mac display"
                ),
                "device_id": PropertySchema(
                    type: "string",
                    description: "Optional simulator device UDID. If omitted, uses the booted simulator."
                ),
            ],
            required: []
        )
    )

    // MARK: - Git Workflow Tools

    static let gitStatus = ToolSchema(
        name: "git_status",
        description: """
            Show the git working tree status for the project. Returns structured JSON with \
            staged, unstaged, and untracked files grouped by category. \
            Includes the current branch name and whether the tree is clean.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    static let gitLog = ToolSchema(
        name: "git_log",
        description: """
            Show the git commit log for the project. Returns structured JSON with commit hash, \
            author, date, and message for each entry. Defaults to the last 20 commits. \
            Optionally filter by file path or limit the number of entries.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "limit": PropertySchema(
                    type: "integer",
                    description: "Maximum number of commits to return. Default 20, max 100."
                ),
                "file": PropertySchema(
                    type: "string",
                    description: "Filter log to commits affecting this file path."
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    static let gitDiff = ToolSchema(
        name: "git_diff",
        description: """
            Show git diff output for the project. By default shows unstaged changes. \
            Use staged=true to show staged changes, or provide a commit ref to diff against. \
            Returns unified diff output with file paths and line numbers.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "staged": PropertySchema(
                    type: "boolean",
                    description: "Show staged (cached) changes instead of unstaged. Default false."
                ),
                "ref": PropertySchema(
                    type: "string",
                    description: "Commit reference to diff against (e.g. 'HEAD~3', 'main', a commit SHA)."
                ),
                "file": PropertySchema(
                    type: "string",
                    description: "Limit diff to a specific file path."
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    // MARK: - Code Analysis Tools

    static let findUnusedCode = ToolSchema(
        name: "find_unused_code",
        description: """
            Detect potentially unused code in a Swift project. Scans for types, functions, \
            and properties that are declared but never referenced elsewhere. \
            Returns JSON array of {symbol, kind, file, line, confidence}. \
            Confidence is 'high' for internal symbols with zero references, 'medium' for \
            symbols that may be used via protocols or dynamic dispatch.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory to scan. Defaults to working directory."
                ),
                "kind": PropertySchema(
                    type: "string",
                    description: "Filter by symbol kind: 'type', 'function', 'property', or 'all'. Default 'all'."
                ),
            ],
            required: []
        )
    )

    static let lintCheck = ToolSchema(
        name: "lint_check",
        description: """
            Run lint checks on a Swift project using SwiftLint (if available) or built-in \
            heuristic checks. Returns JSON array of {file, line, column, severity, rule, message}. \
            Severity is 'error' or 'warning'. If SwiftLint is installed, uses it directly; \
            otherwise falls back to pattern-based checks for common issues.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory or specific file to lint. Defaults to working directory."
                ),
                "fix": PropertySchema(
                    type: "boolean",
                    description: "Auto-fix correctable violations (SwiftLint --fix). Default false."
                ),
            ],
            required: []
        )
    )

    // MARK: - iOS Simulator Tools

    static let simulatorList = ToolSchema(
        name: "simulator_list",
        description: """
            List available iOS simulators with their state (booted/shutdown), runtime, \
            and device UDID. Returns JSON array of {name, udid, state, runtime}. \
            Use the UDID from this list for other simulator commands.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "filter": PropertySchema(
                    type: "string",
                    description: "Filter by state: 'booted', 'shutdown', or 'all'. Default 'all'."
                ),
            ],
            required: []
        )
    )

    static let simulatorBuildRun = ToolSchema(
        name: "simulator_build_run",
        description: """
            Build an Xcode project for the iOS Simulator and optionally install/launch it. \
            Auto-detects scheme and destination. Returns build result with errors/warnings, \
            and install/launch status if requested. Boots the simulator if needed.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "scheme": PropertySchema(
                    type: "string",
                    description: "Xcode scheme name. Auto-detected if not specified."
                ),
                "device_id": PropertySchema(
                    type: "string",
                    description: "Simulator UDID to target. Uses booted simulator if omitted."
                ),
                "install": PropertySchema(
                    type: "boolean",
                    description: "Install the built app to the simulator. Default true."
                ),
                "launch": PropertySchema(
                    type: "boolean",
                    description: "Launch the app after install. Default true."
                ),
                "path": PropertySchema(
                    type: "string",
                    description: "Project directory. Defaults to working directory."
                ),
            ],
            required: []
        )
    )

    static let simulatorAppManage = ToolSchema(
        name: "simulator_app_manage",
        description: """
            Manage apps on the iOS Simulator — launch, terminate, uninstall, or get info. \
            Requires either a bundle identifier or an action that operates on the simulator itself.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "action": PropertySchema(
                    type: "string",
                    description: "Action to perform: 'launch', 'terminate', 'uninstall', 'list_apps', 'boot', 'shutdown'."
                ),
                "bundle_id": PropertySchema(
                    type: "string",
                    description: "App bundle identifier (e.g. 'com.forgeandcode.BookBuddy'). Required for launch/terminate/uninstall."
                ),
                "device_id": PropertySchema(
                    type: "string",
                    description: "Simulator UDID. Uses booted simulator if omitted."
                ),
            ],
            required: ["action"]
        )
    )

    static let simulatorScreenshot = ToolSchema(
        name: "simulator_screenshot",
        description: """
            Take a screenshot of the iOS Simulator screen. Saves to a temporary file \
            and returns the file path. Optionally specify a device if multiple simulators are booted.
            """,
        inputSchema: JSONSchema(
            type: "object",
            properties: [
                "device_id": PropertySchema(
                    type: "string",
                    description: "Simulator UDID. Uses booted simulator if omitted."
                ),
                "output_path": PropertySchema(
                    type: "string",
                    description: "Custom output file path. Defaults to a timestamped file in /tmp."
                ),
            ],
            required: []
        )
    )
}
