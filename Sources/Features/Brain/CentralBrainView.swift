import SwiftUI

/// Displays the central brain (~/.cortana/brain/) — DIRECTOR-BRIEF, corrections,
/// patterns, anti-patterns, architecture decisions, and identity files.
struct CentralBrainView: View {
    @ObservedObject private var store = CentralBrainStore.shared
    @State private var selectedSection: BrainSection = .directorBrief

    enum BrainSection: String, CaseIterable, Identifiable {
        case directorBrief = "Director Brief"
        case corrections = "Corrections"
        case patterns = "Patterns"
        case antiPatterns = "Anti-Patterns"
        case architecture = "Architecture Decisions"
        case projects = "Project Notes"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .directorBrief: return "doc.text.fill"
            case .corrections: return "exclamationmark.triangle.fill"
            case .patterns: return "checkmark.seal.fill"
            case .antiPatterns: return "xmark.seal.fill"
            case .architecture: return "building.columns.fill"
            case .projects: return "folder.fill"
            }
        }

        var color: Color {
            switch self {
            case .directorBrief: return .blue
            case .corrections: return .red
            case .patterns: return .green
            case .antiPatterns: return .orange
            case .architecture: return .purple
            case .projects: return .cyan
            }
        }
    }

    var body: some View {
        HSplitView {
            sectionList
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            contentPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            store.refresh()
            store.startWatching()
        }
        .onDisappear {
            store.stopWatching()
        }
    }

    // MARK: - Section List

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14)).foregroundStyle(.purple)
                Text("Central Brain")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider()

            List(BrainSection.allCases, selection: $selectedSection) { section in
                HStack(spacing: 8) {
                    Image(systemName: section.icon)
                        .font(.system(size: 10))
                        .foregroundStyle(section.color)
                        .frame(width: 16)
                    Text(section.rawValue)
                        .font(.system(size: 11))
                    Spacer()
                    if hasContent(section) {
                        Circle().fill(section.color.opacity(0.5)).frame(width: 6, height: 6)
                    }
                }
                .tag(section)
            }
            .listStyle(.sidebar)

            Divider()
            if let refresh = store.lastRefresh {
                Text("Updated \(refresh, style: .relative) ago")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(Palette.cardBackground)
    }

    // MARK: - Content Panel

    @ViewBuilder
    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: selectedSection.icon)
                    .foregroundStyle(selectedSection.color)
                Text(selectedSection.rawValue)
                    .font(.headline)
                Spacer()
                if let content = contentFor(selectedSection), !content.isEmpty {
                    Text("\(content.components(separatedBy: "\n").count) lines")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            // Content
            if selectedSection == .projects {
                projectNotesView
            } else if let content = contentFor(selectedSection) {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                emptyState
            }
        }
    }

    private var projectNotesView: some View {
        Group {
            if store.projectNotes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(store.projectNotes.keys.sorted(), id: \.self) { project in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 10)).foregroundStyle(.cyan)
                                    Text(project)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                Text(store.projectNotes[project] ?? "")
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Palette.cardBackground.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedSection.icon)
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No \(selectedSection.rawValue.lowercased()) found")
                .font(.caption).foregroundStyle(.secondary)
            Text("~/.cortana/brain/")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func contentFor(_ section: BrainSection) -> String? {
        switch section {
        case .directorBrief: return store.directorBrief
        case .corrections: return store.corrections
        case .patterns: return store.patterns
        case .antiPatterns: return store.antiPatterns
        case .architecture: return store.architectureDecisions
        case .projects: return nil // handled separately
        }
    }

    private func hasContent(_ section: BrainSection) -> Bool {
        switch section {
        case .projects: return !store.projectNotes.isEmpty
        default: return contentFor(section) != nil
        }
    }
}
