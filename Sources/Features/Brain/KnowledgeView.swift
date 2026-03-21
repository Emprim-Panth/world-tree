import SwiftUI
import GRDB

// MARK: - Model

struct BrainKnowledgeEntry: Identifiable, Hashable {
    let id: String
    let type: String
    let title: String
    let content: String
    let project: String?
    let severity: String?
    let createdAt: String
    let timesReferenced: Int

    var typeColor: Color {
        switch type.uppercased() {
        case "CORRECTION": return .red
        case "MISTAKE": return .orange
        case "ANTI_PATTERN": return .yellow
        case "DECISION": return .blue
        case "PATTERN": return .green
        case "FIX": return .teal
        default: return .secondary
        }
    }

    var typeIcon: String {
        switch type.uppercased() {
        case "CORRECTION": return "exclamationmark.circle.fill"
        case "MISTAKE": return "xmark.circle.fill"
        case "ANTI_PATTERN": return "nosign"
        case "DECISION": return "checkmark.seal.fill"
        case "PATTERN": return "repeat.circle.fill"
        case "FIX": return "wrench.and.screwdriver.fill"
        default: return "doc.text.fill"
        }
    }

    var normalizedType: String {
        switch type.uppercased() {
        case "ANTI_PATTERN": return "ANTI_PATTERN"
        default: return type.uppercased()
        }
    }
}

// MARK: - Store

@MainActor
final class KnowledgeStore: ObservableObject {
    static let shared = KnowledgeStore()

    @Published private(set) var entries: [BrainKnowledgeEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var stats = KnowledgeStats()

    private init() {}

    func load() async {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let results = try await dbPool.read { db -> [BrainKnowledgeEntry] in
                guard try db.tableExists("knowledge") else { return [] }
                return try Row.fetchAll(db, sql: """
                    SELECT id, type, title, content, project, severity, created_at, times_referenced
                    FROM knowledge
                    WHERE is_active = 1
                    ORDER BY
                        CASE type
                            WHEN 'CORRECTION' THEN 0
                            WHEN 'correction' THEN 0
                            WHEN 'MISTAKE' THEN 1
                            WHEN 'mistake' THEN 1
                            WHEN 'ANTI_PATTERN' THEN 2
                            WHEN 'anti_pattern' THEN 2
                            WHEN 'DECISION' THEN 3
                            WHEN 'decision' THEN 3
                            WHEN 'PATTERN' THEN 4
                            WHEN 'pattern' THEN 4
                            ELSE 5
                        END,
                        created_at DESC
                    """).map { row in
                    BrainKnowledgeEntry(
                        id: row["id"] as? String ?? UUID().uuidString,
                        type: row["type"] as? String ?? "unknown",
                        title: row["title"] as? String ?? "Untitled",
                        content: row["content"] as? String ?? "",
                        project: row["project"] as? String,
                        severity: row["severity"] as? String,
                        createdAt: row["created_at"] as? String ?? "",
                        timesReferenced: row["times_referenced"] as? Int ?? 0
                    )
                }
            }

            entries = results
            stats = KnowledgeStats(entries: results)
        } catch {
            wtLog("[KnowledgeStore] Load failed: \(error)")
        }
    }

    func search(_ query: String) -> [BrainKnowledgeEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter {
            $0.title.lowercased().contains(q)
            || $0.content.lowercased().contains(q)
            || ($0.project?.lowercased().contains(q) ?? false)
            || $0.type.lowercased().contains(q)
        }
    }
}

struct KnowledgeStats {
    var total: Int = 0
    var corrections: Int = 0
    var decisions: Int = 0
    var patterns: Int = 0
    var mistakes: Int = 0
    var projects: Set<String> = []

    init() {}

    init(entries: [BrainKnowledgeEntry]) {
        total = entries.count
        for e in entries {
            switch e.type.uppercased() {
            case "CORRECTION": corrections += 1
            case "DECISION": decisions += 1
            case "PATTERN": patterns += 1
            case "MISTAKE", "ANTI_PATTERN": mistakes += 1
            default: break
            }
            if let p = e.project, !p.isEmpty { projects.insert(p) }
        }
    }
}

// MARK: - View

struct KnowledgeView: View {
    @StateObject private var store = KnowledgeStore.shared
    @State private var searchQuery = ""
    @State private var selectedEntry: BrainKnowledgeEntry?
    @State private var filterType: String? = nil

    var displayedEntries: [BrainKnowledgeEntry] {
        var base = searchQuery.isEmpty ? store.entries : store.search(searchQuery)
        if let filter = filterType {
            base = base.filter { $0.type.uppercased() == filter.uppercased() }
        }
        return base
    }

    var allTypes: [String] {
        let raw = Set(store.entries.map { $0.type.uppercased() })
        return raw.sorted()
    }

    var body: some View {
        HSplitView {
            // Left: list + filters
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search knowledge...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Stats strip
                HStack(spacing: 6) {
                    statChip("\(store.stats.total)", "entries", .blue)
                    statChip("\(store.stats.corrections)", "fixes", .red)
                    statChip("\(store.stats.decisions)", "decisions", .purple)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Type filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        typeChip(nil, "All")
                        ForEach(allTypes, id: \.self) { t in
                            typeChip(t, t.replacingOccurrences(of: "_", with: " ").capitalized)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                // Entry list
                if store.isLoading {
                    Spacer()
                    ProgressView("Loading knowledge base...")
                    Spacer()
                } else if displayedEntries.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        "No Entries",
                        systemImage: "brain",
                        description: Text(searchQuery.isEmpty ? "No knowledge entries found." : "No matches for \"\(searchQuery)\"")
                    )
                    Spacer()
                } else {
                    List(displayedEntries, selection: $selectedEntry) { entry in
                        KnowledgeRowView(entry: entry)
                            .tag(entry)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(minWidth: 260, idealWidth: 280, maxWidth: 340)

            // Right: detail
            if let entry = selectedEntry {
                KnowledgeDetailView(entry: entry)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "brain")
                        .font(.system(size: 48))
                        .foregroundStyle(Color.purple.opacity(0.5))
                    Text("Select an entry")
                        .foregroundStyle(.secondary)
                    Text("\(store.stats.total) entries · \(store.stats.projects.count) projects")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if store.entries.isEmpty {
                await store.load()
            }
        }
    }

    @ViewBuilder
    private func statChip(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func typeChip(_ type: String?, _ label: String) -> some View {
        let isSelected = filterType == type
        Button {
            filterType = type
        } label: {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Row

struct KnowledgeRowView: View {
    let entry: BrainKnowledgeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.typeIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(entry.typeColor)
                Text(entry.normalizedType.replacingOccurrences(of: "_", with: " "))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.typeColor)
                Spacer()
                if let proj = entry.project, !proj.isEmpty {
                    Text(proj)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Text(entry.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct KnowledgeDetailView: View {
    let entry: BrainKnowledgeEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: entry.typeIcon)
                            .font(.system(size: 16))
                            .foregroundStyle(entry.typeColor)
                        Text(entry.normalizedType.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(entry.typeColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(entry.typeColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        Spacer()
                        if entry.timesReferenced > 0 {
                            Label("\(entry.timesReferenced) references", systemImage: "arrow.trianglehead.clockwise")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(entry.title)
                        .font(.title3.bold())
                        .textSelection(.enabled)

                    HStack(spacing: 12) {
                        if let proj = entry.project, !proj.isEmpty {
                            Label(proj, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let sev = entry.severity, !sev.isEmpty {
                            Label(sev, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Label(formattedDate(entry.createdAt), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(Color(NSColor.windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))

                // Content
                VStack(alignment: .leading, spacing: 8) {
                    Text("Content")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(entry.content)
                        .font(.system(.body, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(4)
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(20)
        }
    }

    private func formattedDate(_ raw: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = fmt.date(from: raw) {
            let out = DateFormatter()
            out.dateStyle = .medium
            return out.string(from: date)
        }
        return raw.prefix(10).description
    }
}
