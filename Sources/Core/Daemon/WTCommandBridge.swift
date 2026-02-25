import Foundation
import AppKit

private extension String {
    var osascriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - WTCommand (local definition — no CortanaCore dependency)

/// Flat representation of a command written by cortana-daemon to wt-commands.jsonl.
/// All action-specific fields are optional; only those relevant to `type` will be set.
private struct WTCommand: Decodable {
    let id: String
    let type: String
    // notify
    var title: String?
    var body: String?
    var subtitle: String?
    var sound: Bool?
    // openConversation
    var sessionId: String?
    // injectMessage
    var content: String?
    var role: String?
    // showBadge / speak / copyToClipboard
    var text: String?
    var color: String?
    var duration: Double?
    var voice: String?
    // openFile
    var path: String?
    // openURL
    var url: String?
    // runShortcut
    var name: String?
}

// MARK: - PeekabooBridgeServer

/// Watches ~/.cortana/wt-commands.jsonl for commands pushed by cortana-daemon.
/// This is the reverse channel: daemon → World Tree.
///
/// Start with `WTCommandBridge.shared.start()` on app launch.
@MainActor
final class WTCommandBridge: ObservableObject {
    static let shared = WTCommandBridge()

    @Published var lastBadge: BadgeState?

    private let commandsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cortana/wt-commands.jsonl").path
    private var source: DispatchSourceFileSystemObject?
    private nonisolated(unsafe) var fileHandle: FileHandle?
    private nonisolated(unsafe) var bytesRead: UInt64 = 0
    private let ioLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        if !FileManager.default.fileExists(atPath: commandsPath) {
            FileManager.default.createFile(atPath: commandsPath, contents: nil)
        }

        guard let fh = FileHandle(forReadingAtPath: commandsPath) else {
            canvasLog("[WTCommandBridge] failed to open \(commandsPath)")
            return
        }
        fileHandle = fh
        bytesRead = fh.seekToEndOfFile()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fh.fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in self?.readNewLines() }
        src.resume()
        source = src

        canvasLog("[WTCommandBridge] watching \(commandsPath) from offset \(bytesRead)")
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - Reading

    private nonisolated func readNewLines() {
        ioLock.lock()
        guard let fh = fileHandle else { ioLock.unlock(); return }
        fh.seek(toFileOffset: bytesRead)
        let data = fh.readDataToEndOfFile()
        if !data.isEmpty { bytesRead += UInt64(data.count) }
        ioLock.unlock()

        guard !data.isEmpty else { return }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let cmd = try? JSONDecoder().decode(WTCommand.self, from: lineData)
            else { continue }
            Task { @MainActor in self.dispatch(cmd) }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ cmd: WTCommand) {
        canvasLog("[WTCommandBridge] \(cmd.id): \(cmd.type)")
        switch cmd.type {
        case "notify":
            sendNotification(
                title: cmd.title ?? "",
                body: cmd.body ?? "",
                subtitle: cmd.subtitle,
                sound: cmd.sound ?? false
            )

        case "focus":
            NSApp.activate(ignoringOtherApps: true)

        case "openConversation":
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .openConversation,
                object: nil,
                userInfo: ["sessionId": cmd.sessionId ?? ""]
            )

        case "injectMessage":
            NotificationCenter.default.post(
                name: .injectMessage,
                object: nil,
                userInfo: ["content": cmd.content ?? "", "role": cmd.role ?? "assistant"]
            )

        case "showBadge":
            let duration = cmd.duration ?? 3.0
            lastBadge = BadgeState(
                text: cmd.text ?? "",
                color: cmd.color ?? "blue",
                expiresAt: Date().addingTimeInterval(duration)
            )
            let badgeText = cmd.text ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                if self?.lastBadge?.text == badgeText { self?.lastBadge = nil }
            }

        case "refreshHivemind":
            NotificationCenter.default.post(name: .refreshHivemind, object: nil)

        case "openFile":
            if let p = cmd.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }

        case "openURL":
            if let s = cmd.url, let url = URL(string: s) { NSWorkspace.shared.open(url) }

        case "runShortcut":
            let n = cmd.name ?? ""
            let encoded = n.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? n
            if let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
                NSWorkspace.shared.open(url)
            }

        case "copyToClipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd.text ?? "", forType: .string)

        case "speak":
            let task = Process()
            task.launchPath = "/usr/bin/say"
            task.arguments = [cmd.text ?? ""]
            try? task.run()

        default:
            canvasLog("[WTCommandBridge] unknown command type: \(cmd.type)")
        }
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String, subtitle: String?, sound: Bool) {
        var script = "display notification \"\(body.osascriptEscaped)\" with title \"\(title.osascriptEscaped)\""
        if let sub = subtitle { script += " subtitle \"\(sub.osascriptEscaped)\"" }
        if sound { script += " sound name \"Ping\"" }

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

// MARK: - Supporting Types

struct BadgeState {
    let text: String
    let color: String
    let expiresAt: Date
}

// MARK: - Notification Names

extension Notification.Name {
    static let openConversation = Notification.Name("cortana.openConversation")
    static let injectMessage    = Notification.Name("cortana.injectMessage")
    static let refreshHivemind  = Notification.Name("cortana.refreshHivemind")
}
