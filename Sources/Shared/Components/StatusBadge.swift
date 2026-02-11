import SwiftUI

struct StatusBadge: View {
    let status: BranchStatus

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }

    private var label: String {
        switch status {
        case .active: "Active"
        case .completed: "Done"
        case .archived: "Archived"
        case .failed: "Failed"
        }
    }

    private var color: Color {
        switch status {
        case .active: .green
        case .completed: .blue
        case .archived: .secondary
        case .failed: .red
        }
    }
}
