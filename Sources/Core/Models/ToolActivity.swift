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
        default: return "Running \(name)..."
        }
    }

    private func extractPath() -> String {
        // Try to extract file_path from the input JSON string
        if let data = input.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = json["file_path"] as? String {
            return (path as NSString).lastPathComponent
        }
        return "file"
    }
}
