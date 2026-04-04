import SwiftUI

// MARK: - Tree Node Model

enum BrainNode: Hashable, Identifiable {
    case directorBrief
    case cicManifest
    case cicFile(key: String, label: String)
    case galacticaManifest
    case galacticaLearnings
    case galacticaProfile(callsign: String)
    case pegasusManifest
    case pegasusLearnings
    case pegasusProfile(callsign: String)
    case project(name: String)
    case knowledgeFile(key: String, label: String)

    var id: String {
        switch self {
        case .directorBrief:              return "director-brief"
        case .cicManifest:                return "cic-manifest"
        case .cicFile(let k, _):          return "cic-\(k)"
        case .galacticaManifest:          return "galactica-manifest"
        case .galacticaLearnings:         return "galactica-learnings"
        case .galacticaProfile(let c):    return "galactica-\(c)"
        case .pegasusManifest:            return "pegasus-manifest"
        case .pegasusLearnings:           return "pegasus-learnings"
        case .pegasusProfile(let c):      return "pegasus-\(c)"
        case .project(let n):             return "project-\(n)"
        case .knowledgeFile(let k, _):    return "knowledge-\(k)"
        }
    }

    var icon: String {
        switch self {
        case .directorBrief:              return "doc.text.fill"
        case .cicManifest:                return "shield.fill"
        case .cicFile:                    return "doc.plaintext"
        case .galacticaManifest:          return "airplane"
        case .galacticaLearnings:         return "book.fill"
        case .galacticaProfile:           return "person.fill"
        case .pegasusManifest:            return "gamecontroller.fill"
        case .pegasusLearnings:           return "book.fill"
        case .pegasusProfile:             return "person.fill"
        case .project:                    return "folder.fill"
        case .knowledgeFile(let k, _):
            switch k {
            case "corrections":           return "exclamationmark.triangle.fill"
            case "patterns":              return "checkmark.seal.fill"
            case "anti-patterns":         return "xmark.seal.fill"
            case "architecture":          return "building.columns.fill"
            default:                      return "doc.plaintext"
            }
        }
    }

    var color: Color {
        switch self {
        case .directorBrief:              return Palette.info
        case .cicManifest, .cicFile:      return .purple
        case .galacticaManifest, .galacticaLearnings, .galacticaProfile: return .cyan
        case .pegasusManifest, .pegasusLearnings, .pegasusProfile:       return .indigo
        case .project:                    return Palette.exploring
        case .knowledgeFile(let k, _):
            switch k {
            case "corrections":           return Palette.error
            case "patterns":              return Palette.success
            case "anti-patterns":         return Palette.warning
            case "architecture":          return .purple
            default:                      return Palette.neutral
            }
        }
    }

    var label: String {
        switch self {
        case .directorBrief:                  return "Director Brief"
        case .cicManifest:                    return "CIC Manifest"
        case .cicFile(_, let l):              return l
        case .galacticaManifest:              return "Fleet Charter"
        case .galacticaLearnings:             return "Learnings"
        case .galacticaProfile(let c):        return c
        case .pegasusManifest:                return "Fleet Charter"
        case .pegasusLearnings:               return "Learnings"
        case .pegasusProfile(let c):          return c
        case .project(let n):                 return n
        case .knowledgeFile(_, let l):        return l
        }
    }
}

// MARK: - Main View

struct CentralBrainView: View {
    var store = CentralBrainStore.shared
    @State private var selected: BrainNode? = .directorBrief
    @State private var expandedSections: Set<String> = ["cic", "knowledge", "projects"]

    var body: some View {
        HSplitView {
            treePane
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
            contentPane
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

    // MARK: - Tree Pane

    private var treePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13)).foregroundStyle(.purple)
                Text("Brain")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Director Brief — always at top
                    nodeRow(.directorBrief, indent: 0)

                    // CIC
                    sectionHeader("🎯 CIC", key: "cic", color: .purple)
                    if expandedSections.contains("cic") {
                        nodeRow(.cicManifest, indent: 1)
                        nodeRow(.cicFile(key: "cortana",   label: "Cortana"),          indent: 1)
                        nodeRow(.cicFile(key: "principles", label: "Operating Principles"), indent: 1)
                        nodeRow(.cicFile(key: "behavioral", label: "Behavioral Profile"),   indent: 1)
                        nodeRow(.cicFile(key: "relationship", label: "Relationship Context"), indent: 1)
                    }

                    // Galactica
                    sectionHeader("🚀 Galactica", key: "galactica", color: .cyan)
                    if expandedSections.contains("galactica") {
                        nodeRow(.galacticaManifest, indent: 1)
                        nodeRow(.galacticaLearnings, indent: 1)
                        ForEach(store.galacticaProfiles.keys.sorted(), id: \.self) { callsign in
                            nodeRow(.galacticaProfile(callsign: callsign), indent: 1)
                        }
                    }

                    // Pegasus
                    sectionHeader("🛸 Pegasus", key: "pegasus", color: .indigo)
                    if expandedSections.contains("pegasus") {
                        nodeRow(.pegasusManifest, indent: 1)
                        nodeRow(.pegasusLearnings, indent: 1)
                        ForEach(store.pegasusProfiles.keys.sorted(), id: \.self) { callsign in
                            nodeRow(.pegasusProfile(callsign: callsign), indent: 1)
                        }
                    }

                    // Projects
                    sectionHeader("📁 Projects", key: "projects", color: Palette.exploring)
                    if expandedSections.contains("projects") {
                        ForEach(store.projectNotes.keys.sorted(), id: \.self) { name in
                            nodeRow(.project(name: name), indent: 1)
                        }
                    }

                    // Knowledge
                    sectionHeader("📚 Knowledge", key: "knowledge", color: Palette.success)
                    if expandedSections.contains("knowledge") {
                        nodeRow(.knowledgeFile(key: "corrections",  label: "Corrections"),   indent: 1)
                        nodeRow(.knowledgeFile(key: "patterns",     label: "Patterns"),       indent: 1)
                        nodeRow(.knowledgeFile(key: "anti-patterns", label: "Anti-Patterns"), indent: 1)
                        nodeRow(.knowledgeFile(key: "architecture",  label: "Decisions"),     indent: 1)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            if let refresh = store.lastRefresh {
                Text("Updated \(refresh, style: .relative) ago")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(Palette.cardBackground)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, key: String, color: Color) -> some View {
        Button {
            if expandedSections.contains(key) {
                expandedSections.remove(key)
            } else {
                expandedSections.insert(key)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expandedSections.contains(key) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func nodeRow(_ node: BrainNode, indent: Int) -> some View {
        let isSelected = selected == node
        Button {
            selected = node
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: CGFloat(indent) * 16)
                Image(systemName: node.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(node.color)
                    .frame(width: 14)
                Text(node.label)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
                if hasContent(node) {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.6) : node.color.opacity(0.5))
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? node.color.opacity(0.7) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func hasContent(_ node: BrainNode) -> Bool {
        contentFor(node) != nil
    }

    // MARK: - Content Pane

    @ViewBuilder
    private var contentPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let node = selected {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: node.icon).foregroundStyle(node.color)
                    Text(node.label).font(.headline)
                    Spacer()
                    if let content = contentFor(node) {
                        Text("\(content.components(separatedBy: "\n").count) lines")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                Divider()

                if let content = contentFor(node), !content.isEmpty {
                    ScrollView {
                        Text(content)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                } else {
                    emptyState(for: node)
                }
            } else {
                emptyStateDefault
            }
        }
    }

    private func contentFor(_ node: BrainNode) -> String? {
        switch node {
        case .directorBrief:                  return store.directorBrief
        case .cicManifest:                    return store.cicManifest
        case .cicFile(let k, _):
            switch k {
            case "cortana":                   return store.whoIAm
            case "principles":                return store.operatingPrinciples
            case "behavioral":                return store.behavioralProfile
            case "relationship":              return store.relationshipContext
            default:                          return nil
            }
        case .galacticaManifest:              return store.galacticaManifest
        case .galacticaLearnings:             return store.galacticaLearnings
        case .galacticaProfile(let c):        return store.galacticaProfiles[c]
        case .pegasusManifest:                return store.pegasusManifest
        case .pegasusLearnings:               return store.pegasusLearnings
        case .pegasusProfile(let c):          return store.pegasusProfiles[c]
        case .project(let n):                 return store.projectNotes[n]
        case .knowledgeFile(let k, _):
            switch k {
            case "corrections":               return store.corrections
            case "patterns":                  return store.patterns
            case "anti-patterns":             return store.antiPatterns
            case "architecture":              return store.architectureDecisions
            default:                          return nil
            }
        }
    }

    @ViewBuilder
    private func emptyState(for node: BrainNode) -> some View {
        VStack(spacing: 8) {
            Image(systemName: node.icon)
                .font(.system(size: 28)).foregroundStyle(.tertiary)
            Text("No content for \(node.label.lowercased())")
                .font(.caption).foregroundStyle(.secondary)
            Text("~/.cortana/brain/")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateDefault: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Select a section")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
