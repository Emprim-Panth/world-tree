import SwiftUI
import GRDB

// MARK: - Skill Model

struct SkillChip: Identifiable, Equatable {
    let id: String          // name
    let name: String
    let description: String
    let tags: [String]
    let useCount: Int

    var icon: String {
        if tags.contains("ios")    { return "iphone" }
        if tags.contains("design") { return "paintbrush" }
        if tags.contains("test")   { return "checkmark.shield" }
        if tags.contains("git")    { return "arrow.triangle.branch" }
        if tags.contains("deploy") { return "arrow.up.circle" }
        if tags.contains("ai")     { return "brain" }
        if tags.contains("memory") { return "memorychip" }
        if tags.contains("learn")  { return "book.closed" }
        if tags.contains("macos")  { return "apple.logo" }
        return "terminal"
    }
}

// MARK: - Skills Palette Store

@MainActor
final class SkillsPaletteStore: ObservableObject {
    static let shared = SkillsPaletteStore()

    @Published private(set) var suggestedSkills: [SkillChip] = []

    private var lastProject: String = ""

    private init() {}

    func refresh(project: String, workingDirectory: String) {
        guard project != lastProject || suggestedSkills.isEmpty else { return }
        lastProject = project

        Task {
            let chips = await Self.fetchSkills(project: project, workingDirectory: workingDirectory)
            self.suggestedSkills = chips
        }
    }

    private static func fetchSkills(project: String, workingDirectory: String) async -> [SkillChip] {
        // Infer project type from working directory for tag matching
        let projectTags = inferProjectTags(project: project, workingDirectory: workingDirectory)

        do {
            let rows = try await DatabaseManager.shared.asyncRead { db -> [Row] in
                guard try db.tableExists("skills") else { return [] }
                return try Row.fetchAll(db, sql: """
                    SELECT name, description, tags, use_count
                    FROM skills
                    WHERE user_invocable = 1
                    ORDER BY use_count DESC, name ASC
                    LIMIT 30
                    """)
            }

            var chips = rows.compactMap { row -> SkillChip? in
                let name: String = row["name"] ?? ""
                let description: String = row["description"] ?? ""
                let tagsJson: String = row["tags"] ?? "[]"
                let useCount: Int = row["use_count"] ?? 0
                guard !name.isEmpty else { return nil }
                let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJson.utf8))) ?? []
                return SkillChip(id: name, name: name, description: description, tags: tags, useCount: useCount)
            }

            // Sort: skills matching project type float to top, then by use count
            chips.sort { a, b in
                let aMatch = a.tags.contains(where: { projectTags.contains($0) })
                let bMatch = b.tags.contains(where: { projectTags.contains($0) })
                if aMatch != bMatch { return aMatch }
                return a.useCount > b.useCount
            }

            return Array(chips.prefix(12))
        } catch {
            return []
        }
    }

    private static func inferProjectTags(project: String, workingDirectory: String) -> Set<String> {
        var tags = Set<String>()
        let lower = (project + workingDirectory).lowercased()
        if lower.contains("bookbuddy") || lower.contains("homeschool") || lower.contains("impulse") ||
           lower.contains("archon") || lower.contains("studio") { tags.insert("ios") }
        if lower.contains("worldtree") || lower.contains("world-tree") { tags.insert("macos") }
        if lower.contains("archon") || lower.contains("forge") { tags.insert("design") }
        if lower.contains("cortana") || lower.contains("ark") { tags.insert("ai") }
        tags.insert("git")  // always relevant
        return tags
    }
}

// MARK: - Skills Palette View

struct SkillsPaletteView: View {
    let workingDirectory: String
    let project: String
    @Binding var currentInput: String
    let isProcessing: Bool

    @ObservedObject private var store = SkillsPaletteStore.shared
    @State private var hoveredSkill: String? = nil

    /// Hide palette when user has already started typing or is processing
    private var shouldShow: Bool {
        !isProcessing && currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Always render the container so layout height doesn't shift when palette
        // appears/disappears. Opacity + allowsHitTesting handle show/hide instead.
        if !store.suggestedSkills.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.suggestedSkills) { skill in
                        SkillChipView(
                            skill: skill,
                            isHovered: hoveredSkill == skill.id,
                            onTap: {
                                currentInput = "/\(skill.name) "
                            }
                        )
                        .onHover { hovering in
                            hoveredSkill = hovering ? skill.id : nil
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
            .opacity(shouldShow ? 1 : 0)
            .allowsHitTesting(shouldShow)
            .animation(.easeInOut(duration: 0.15), value: shouldShow)
        }
        EmptyView()
            .onAppear {
                store.refresh(project: project, workingDirectory: workingDirectory)
            }
    }
}

// MARK: - Skill Chip View

private struct SkillChipView: View {
    let skill: SkillChip
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: skill.icon)
                    .font(.system(size: 10, weight: .medium))
                Text("/\(skill.name)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered
                        ? Color.accentColor.opacity(0.15)
                        : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isHovered
                        ? Color.accentColor.opacity(0.4)
                        : Color.primary.opacity(0.1),
                        lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(skill.description)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
}
