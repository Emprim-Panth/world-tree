import Foundation

/// Static JSON Schema definitions for the tools Canvas gives Claude.
enum CanvasTools {

    /// All tool definitions. The last one carries cache_control for prompt caching.
    static func definitions() -> [ToolSchema] {
        var tools = [readFile, writeFile, editFile, bash, glob, grep]
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
}
