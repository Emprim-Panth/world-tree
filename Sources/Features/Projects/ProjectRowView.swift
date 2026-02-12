import SwiftUI

struct ProjectRowView: View {
    let project: CachedProject
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Type icon
                Image(systemName: project.type.icon)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 16)
                
                // Project info
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.caption)
                        .fontWeight(isSelected ? .medium : .regular)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        if let branch = project.gitBranch {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.branch")
                                    .font(.caption2)
                                Text(branch)
                                    .font(.caption2)
                            }
                            .foregroundStyle(.tertiary)
                            
                            if project.gitDirty {
                                Circle()
                                    .fill(.orange)
                                    .frame(width: 4, height: 4)
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help(project.path)
    }
}
