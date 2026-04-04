import Foundation
import Observation

/// Reads the central brain at ~/.cortana/brain/ — full org structure:
/// CIC (identity), Galactica/Pegasus fleets, Projects, and shared Knowledge.
/// File watchers auto-refresh on changes.
@MainActor
@Observable
final class CentralBrainStore {
    static let shared = CentralBrainStore()

    // MARK: - Director Brief
    private(set) var directorBrief: String?

    // MARK: - CIC
    private(set) var cicManifest: String?
    private(set) var whoIAm: String?           // cortana.md
    private(set) var operatingPrinciples: String?
    private(set) var behavioralProfile: String?
    private(set) var relationshipContext: String?

    // MARK: - Knowledge
    private(set) var corrections: String?
    private(set) var patterns: String?
    private(set) var antiPatterns: String?
    private(set) var architectureDecisions: String?

    // MARK: - Fleets
    private(set) var galacticaManifest: String?
    private(set) var galacticaLearnings: String?
    private(set) var galacticaProfiles: [String: String] = [:]   // callsign → profile.md content

    private(set) var pegasusManifest: String?
    private(set) var pegasusLearnings: String?
    private(set) var pegasusProfiles: [String: String] = [:]

    // MARK: - Projects
    private(set) var projectNotes: [String: String] = [:]        // project → _context.md content

    private(set) var lastRefresh: Date?

    private let fm = FileManager.default
    private let brainDir: URL
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    private init() {
        let home = fm.homeDirectoryForCurrentUser
        brainDir = home.appendingPathComponent(".cortana/brain")
        refresh()
    }

    // MARK: - Paths

    private var directorBriefPath: URL { brainDir.appendingPathComponent("DIRECTOR-BRIEF.md") }
    private var knowledgeDir: URL      { brainDir.appendingPathComponent("Knowledge") }
    private var cicDir: URL            { brainDir.appendingPathComponent("CIC") }
    private var galacticaDir: URL      { brainDir.appendingPathComponent("Galactica") }
    private var pegasusDir: URL        { brainDir.appendingPathComponent("Pegasus") }
    private var projectsDir: URL       { brainDir.appendingPathComponent("projects") }

    // MARK: - Refresh

    func refresh() {
        directorBrief = readFile(directorBriefPath)

        // CIC
        cicManifest         = readFile(cicDir.appendingPathComponent("_manifest.md"))
        whoIAm              = readFile(cicDir.appendingPathComponent("cortana.md"))
        operatingPrinciples = readFile(cicDir.appendingPathComponent("operating-principles.md"))
        behavioralProfile   = readFile(cicDir.appendingPathComponent("behavioral-profile.md"))
        relationshipContext = readFile(cicDir.appendingPathComponent("relationship-context.md"))

        // Knowledge
        corrections         = readFile(knowledgeDir.appendingPathComponent("corrections.md"))
        patterns            = readFile(knowledgeDir.appendingPathComponent("patterns.md"))
        antiPatterns        = readFile(knowledgeDir.appendingPathComponent("anti-patterns.md"))
        architectureDecisions = readFile(knowledgeDir.appendingPathComponent("architecture-decisions.md"))

        // Fleets
        galacticaManifest  = readFile(galacticaDir.appendingPathComponent("_manifest.md"))
        galacticaLearnings = readFile(galacticaDir.appendingPathComponent("learnings.md"))
        galacticaProfiles  = loadProfiles(in: galacticaDir)

        pegasusManifest    = readFile(pegasusDir.appendingPathComponent("_manifest.md"))
        pegasusLearnings   = readFile(pegasusDir.appendingPathComponent("learnings.md"))
        pegasusProfiles    = loadProfiles(in: pegasusDir)

        // Projects
        loadProjectNotes()

        lastRefresh = Date()
        wtLog("[CentralBrainStore] Refreshed — \(galacticaProfiles.count) Galactica, \(pegasusProfiles.count) Pegasus, \(projectNotes.count) projects")
    }

    private func loadProfiles(in dir: URL) -> [String: String] {
        var profiles: [String: String] = [:]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return profiles }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = entry.lastPathComponent
            if name.hasPrefix("_") { continue }
            if let text = readFile(entry.appendingPathComponent("profile.md")) {
                profiles[name] = text
            }
        }
        return profiles
    }

    private func loadProjectNotes() {
        var notes: [String: String] = [:]
        guard let contents = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for entry in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let contextFile = entry.appendingPathComponent("_context.md")
                let name = entry.lastPathComponent
                if name == "archived" { continue }
                if let text = readFile(contextFile) {
                    notes[name] = text
                }
            }
        }
        projectNotes = notes
    }

    private func readFile(_ url: URL) -> String? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Watch

    func startWatching() {
        let dirsToWatch: [(String, URL)] = [
            ("cic", cicDir),
            ("galactica", galacticaDir),
            ("pegasus", pegasusDir),
            ("knowledge", knowledgeDir),
            ("projects", projectsDir),
        ]
        for (key, dir) in dirsToWatch {
            guard watchers[key] == nil, fm.fileExists(atPath: dir.path) else { continue }
            guard let fd = openFileDescriptor(dir) else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[key] = source
        }
        // Also watch the DIRECTOR-BRIEF directly
        let briefKey = "director-brief"
        if watchers[briefKey] == nil, let fd = openFileDescriptor(directorBriefPath) {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.refresh() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[briefKey] = source
        }
        wtLog("[CentralBrainStore] Watching \(watchers.count) brain directories")
    }

    func stopWatching() {
        for (_, source) in watchers { source.cancel() }
        watchers.removeAll()
    }

    private func openFileDescriptor(_ url: URL) -> Int32? {
        let fd = open(url.path, O_EVTONLY)
        return fd != -1 ? fd : nil
    }

    // MARK: - Write Back

    func appendCorrection(_ text: String) {
        appendToFile(knowledgeDir.appendingPathComponent("corrections.md"), content: text)
        corrections = readFile(knowledgeDir.appendingPathComponent("corrections.md"))
    }

    func appendPattern(_ text: String) {
        appendToFile(knowledgeDir.appendingPathComponent("patterns.md"), content: text)
        patterns = readFile(knowledgeDir.appendingPathComponent("patterns.md"))
    }

    func appendDecision(_ text: String) {
        appendToFile(knowledgeDir.appendingPathComponent("architecture-decisions.md"), content: text)
        architectureDecisions = readFile(knowledgeDir.appendingPathComponent("architecture-decisions.md"))
    }

    private func appendToFile(_ url: URL, content: String) {
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(Data("\n\n\(content)".utf8))
                handle.closeFile()
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
            wtLog("[CentralBrainStore] Appended to \(url.lastPathComponent)")
        } catch {
            wtLog("[CentralBrainStore] Failed to append to \(url.lastPathComponent): \(error)")
        }
    }
}
