import Foundation

/// Static JSON Schema definitions for the tools Canvas gives Claude.
enum CanvasTools {

    /// All tool definitions. The last one carries cache_control for prompt caching.
    static func definitions() -> [ToolSchema] {
        var tools = [readFile, writeFile, editFile, bash, glob, grep,
                     buildProject, runTests, checkpointCreate, checkpointRevert, checkpointList,
                     backgroundRun, listTerminals, terminalOutput, captureScreenshot]
        tools[tools.count - 1].cacheControl = CacheControl(type: "ephemeral")
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
}
