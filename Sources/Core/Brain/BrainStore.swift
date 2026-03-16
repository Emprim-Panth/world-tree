import Foundation
import GRDB

enum BrainCategory: String, CaseIterable, Identifiable {
    case identity, projects, knowledge, sessions
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .identity:  return "Identity"
        case .projects:  return "Projects"
        case .knowledge: return "Knowledge"
        case .sessions:  return "Sessions"
        }
    }
}

struct BrainDocument: Identifiable, Hashable {
    let id: URL  // file path as identity
    var category: BrainCategory
    var title: String
    var content: String
    var lastModified: Date

    init(path: URL, category: BrainCategory) {
        self.id = path
        self.category = category
        self.title = path.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        self.content = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        self.lastModified = (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
    }
}

@MainActor
final class BrainStore: ObservableObject {
    static let shared = BrainStore()

    let brainDirectory: URL
    @Published var documents: [BrainDocument] = []

    private var fsEventStream: FSEventStreamRef?

    private init() {
        let cortanaDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cortana")
        brainDirectory = cortanaDir.appendingPathComponent("brain")
        setupBrainDirectory()
        Task { await reload() }
        startWatching()
    }

    private func setupBrainDirectory() {
        let fm = FileManager.default
        for category in BrainCategory.allCases {
            let dir = brainDirectory.appendingPathComponent(category.rawValue)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        seedIfNeeded()
    }

    func reload() async {
        var docs: [BrainDocument] = []
        let fm = FileManager.default
        for category in BrainCategory.allCases {
            let dir = brainDirectory.appendingPathComponent(category.rawValue)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ).filter({ $0.pathExtension == "md" }) else { continue }
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                docs.append(BrainDocument(path: file, category: category))
            }
        }
        documents = docs
        await reindex(docs)
    }

    func save(_ document: BrainDocument) throws {
        try document.content.write(to: document.id, atomically: true, encoding: .utf8)
        Task { await reload() }
    }

    func newDocument(in category: BrainCategory, title: String) -> BrainDocument {
        let filename = title.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .appending(".md")
        let path = brainDirectory
            .appendingPathComponent(category.rawValue)
            .appendingPathComponent(filename)
        try? "# \(title)\n\n".write(to: path, atomically: true, encoding: .utf8)
        return BrainDocument(path: path, category: category)
    }

    func search(query: String) -> [BrainDocument] {
        guard !query.isEmpty else { return documents }
        let q = query.lowercased()
        return documents.filter {
            $0.title.lowercased().contains(q) || $0.content.lowercased().contains(q)
        }
    }

    private func reindex(_ docs: [BrainDocument]) async {
        guard let dbPool = DatabaseManager.shared.dbPool else { return }
        do {
            try await dbPool.write { db in
                for doc in docs {
                    let preview = String(doc.content.prefix(200))
                    let wordCount = doc.content.split(separator: " ").count
                    try db.execute(sql: """
                        INSERT INTO canvas_brain_index
                            (file_path, category, title, preview, word_count, last_modified, last_indexed)
                        VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
                        ON CONFLICT(file_path) DO UPDATE SET
                            title        = excluded.title,
                            preview      = excluded.preview,
                            word_count   = excluded.word_count,
                            last_modified= excluded.last_modified,
                            last_indexed = CURRENT_TIMESTAMP
                        """,
                        arguments: [
                            doc.id.path,
                            doc.category.rawValue,
                            doc.title,
                            preview,
                            wordCount,
                            doc.lastModified
                        ])
                }
            }
        } catch {
            wtLog("[BrainStore] reindex failed: \(error)")
        }
    }

    private func seedIfNeeded() {
        let whoAmI = brainDirectory.appendingPathComponent("identity/who-i-am.md")
        guard !FileManager.default.fileExists(atPath: whoAmI.path) else { return }

        let identityContent = """
# Who I Am

**Name:** Evan Primeau
**Role:** Software developer building multiple projects under Forge & Code LLC
**Values:** Buy once own forever, privacy first, Apple native, delight over features

## Working Style
- Values competence, directness, and agency
- Doesn't need hand-holding
- Prefers concise, direct answers over verbose explanations

## Active Projects
See `../projects/` for per-project context.
"""
        try? identityContent.write(to: whoAmI, atomically: true, encoding: .utf8)

        let worldtreePath = brainDirectory.appendingPathComponent("projects/WorldTree.md")
        let worldtreeContent = """
# World Tree

**Path:** `/Users/evanprimeau/Development/WorldTree`
**Stack:** macOS SwiftUI + SQLite (GRDB) + Unix socket daemon
**Status:** Active development

## Current Goals
- Slash command system (shipped)
- Brain docs system (this file)
- Hardened chat sessions

## Key Decisions
- SwiftData not used — GRDB for direct SQLite control
- Branching UI removed — adds complexity without split-canvas value
- Single canonical knowledge store at ~/.cortana/brain/
"""
        try? worldtreeContent.write(to: worldtreePath, atomically: true, encoding: .utf8)
    }

    private func startWatching() {
        let pathsToWatch = [brainDirectory.path] as CFArray
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, _, _, _, _, _ in
            Task { @MainActor in
                await BrainStore.shared.reload()
            }
        }

        fsEventStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        )

        if let stream = fsEventStream {
            FSEventStreamScheduleWithRunLoop(
                stream,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue as CFString
            )
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
