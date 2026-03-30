import Foundation
import Observation

/// Reads the central brain at ~/.cortana/brain/ — corrections, patterns,
/// anti-patterns, architecture decisions, DIRECTOR-BRIEF, and identity files.
/// This is the shared knowledge store that persists across all sessions.
@MainActor
@Observable
final class CentralBrainStore {
    static let shared = CentralBrainStore()

    private(set) var directorBrief: String?
    private(set) var corrections: String?
    private(set) var patterns: String?
    private(set) var antiPatterns: String?
    private(set) var architectureDecisions: String?
    private(set) var projectNotes: [String: String] = [:]  // keyed by project name
    private(set) var lastRefresh: Date?

    // Identity files
    private(set) var whoIAm: String?
    private(set) var operatingPrinciples: String?

    private let fm = FileManager.default
    private let brainDir: URL
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]

    private init() {
        let home = fm.homeDirectoryForCurrentUser
        brainDir = home.appendingPathComponent(".cortana/brain")
        refresh()
    }

    // MARK: - File Paths

    private var directorBriefPath: URL { brainDir.appendingPathComponent("DIRECTOR-BRIEF.md") }
    private var correctionsPath: URL { brainDir.appendingPathComponent("knowledge/corrections.md") }
    private var patternsPath: URL { brainDir.appendingPathComponent("knowledge/patterns.md") }
    private var antiPatternsPath: URL { brainDir.appendingPathComponent("knowledge/anti-patterns.md") }
    private var architecturePath: URL { brainDir.appendingPathComponent("knowledge/architecture-decisions.md") }
    private var identityDir: URL { brainDir.appendingPathComponent("identity") }
    private var projectsDir: URL { brainDir.appendingPathComponent("projects") }

    // MARK: - Refresh

    func refresh() {
        directorBrief = readFile(directorBriefPath)
        corrections = readFile(correctionsPath)
        patterns = readFile(patternsPath)
        antiPatterns = readFile(antiPatternsPath)
        architectureDecisions = readFile(architecturePath)
        whoIAm = readFile(identityDir.appendingPathComponent("who-i-am.md"))
        operatingPrinciples = readFile(identityDir.appendingPathComponent("operating-principles.md"))
        loadProjectNotes()
        lastRefresh = Date()
        wtLog("[CentralBrainStore] Refreshed — \(corrections != nil ? "corrections loaded" : "no corrections")")
    }

    private func loadProjectNotes() {
        var notes: [String: String] = [:]
        guard let contents = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.pathExtension == "md" {
            let name = file.deletingPathExtension().lastPathComponent
            if let text = readFile(file) {
                notes[name] = text
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
        let filesToWatch: [(String, URL)] = [
            ("director-brief", directorBriefPath),
            ("corrections", correctionsPath),
            ("patterns", patternsPath),
            ("anti-patterns", antiPatternsPath),
            ("architecture", architecturePath),
        ]

        for (key, url) in filesToWatch {
            guard watchers[key] == nil, fm.fileExists(atPath: url.path) else { continue }
            guard let fd = openFileDescriptor(url) else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[key] = source
        }
        wtLog("[CentralBrainStore] Watching \(watchers.count) brain files")
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

    /// Append a correction to corrections.md
    func appendCorrection(_ text: String) {
        appendToFile(correctionsPath, content: text)
        corrections = readFile(correctionsPath)
    }

    /// Append a pattern to patterns.md
    func appendPattern(_ text: String) {
        appendToFile(patternsPath, content: text)
        patterns = readFile(patternsPath)
    }

    /// Append a decision to architecture-decisions.md
    func appendDecision(_ text: String) {
        appendToFile(architecturePath, content: text)
        architectureDecisions = readFile(architecturePath)
    }

    private func appendToFile(_ url: URL, content: String) {
        do {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
