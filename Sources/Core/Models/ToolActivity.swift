import Foundation

struct ToolActivity: Identifiable {
    let id = UUID()
    let name: String
    let input: String
    var status: ToolStatus
    var output: String?
    let startedAt = Date()

    enum ToolStatus {
        case running
        case completed
        case failed
    }

    var displayDescription: String {
        switch name {
        case "read_file": return "Reading \(extractPath())"
        case "write_file": return "Writing \(extractPath())"
        case "edit_file": return "Editing \(extractPath())"
        case "bash": return "Running command..."
        case "glob": return "Finding files..."
        case "grep": return "Searching files..."
        case "build_project": return "Building project..."
        case "run_tests": return "Running tests..."
        case "checkpoint_create": return "Creating checkpoint..."
        case "checkpoint_revert": return "Reverting to checkpoint..."
        case "checkpoint_list": return "Listing checkpoints..."
        case "background_run": return "Starting background job..."
        case "list_terminals": return "Discovering terminals..."
        case "terminal_output": return "Capturing terminal output..."
        default: return "Running \(name)..."
        }
    }

    /// Whether this activity has diff data (edit_file with old/new strings)
    var hasDiffData: Bool {
        name == "edit_file" && status != .running
    }

    /// Extract diff data from edit_file input
    var diffData: (oldText: String, newText: String, filePath: String?)? {
        guard name == "edit_file" else { return nil }
        guard let json = parsedInput else { return nil }
        guard let oldString = json["old_string"] as? String,
              let newString = json["new_string"] as? String else { return nil }
        let filePath = json["file_path"] as? String
        return (oldString, newString, filePath)
    }

    /// Parsed JSON input
    var parsedInput: [String: Any]? {
        guard let data = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func extractPath() -> String {
        if let path = parsedInput?["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        return "file"
    }
}
