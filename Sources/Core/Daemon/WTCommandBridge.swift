import Foundation
import AppKit
import CortanaCore

private extension String {
    /// Escapes characters that would break an osascript string literal.
    var osascriptEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Watches ~/.cortana/wt-commands.jsonl for commands pushed by cortana-daemon.
/// This is the reverse channel: daemon → World Tree.
///
/// Start with `WTCommandBridge.shared.start()` on app launch.
@MainActor
final class WTCommandBridge: ObservableObject {
    static let shared = WTCommandBridge()

    @Published var lastBadge: BadgeState?

    private let commandsPath = WTCommandWriter.commandsPath
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var bytesRead: UInt64 = 0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        // Ensure file exists
        if !FileManager.default.fileExists(atPath: commandsPath) {
            FileManager.default.createFile(atPath: commandsPath, contents: nil)
        }

        guard let fh = FileHandle(forReadingAtPath: commandsPath) else {
            canvasLog("[WTCommandBridge] failed to open \(commandsPath)")
            return
        }
        fileHandle = fh

        // Seek to end — only process future commands, not historical ones
        bytesRead = fh.seekToEndOfFile()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fh.fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            self?.readNewLines()
        }
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

    private func readNewLines() {
        guard let fh = fileHandle else { return }
        fh.seek(toFileOffset: bytesRead)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        bytesRead += UInt64(data.count)

        let raw = String(data: data, encoding: .utf8) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let cmd = try? JSONDecoder().decode(WTCommand.self, from: lineData)
            else { continue }

            Task { @MainActor in
                self.dispatch(cmd)
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ cmd: WTCommand) {
        canvasLog("[WTCommandBridge] \(cmd.id): \(cmd.action)")
        switch cmd.action {
        case .notify(let title, let body, let subtitle, let sound):
            sendNotification(title: title, body: body, subtitle: subtitle, sound: sound)

        case .focus:
            NSApp.activate(ignoringOtherApps: true)

        case .openConversation(let sessionId):
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .openConversation,
                object: nil,
                userInfo: ["sessionId": sessionId]
            )

        case .injectMessage(let content, let role):
            NotificationCenter.default.post(
                name: .injectMessage,
                object: nil,
                userInfo: ["content": content, "role": role]
            )

        case .showBadge(let text, let color, let duration):
            lastBadge = BadgeState(text: text, color: color, expiresAt: Date().addingTimeInterval(duration))
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                if self?.lastBadge?.text == text { self?.lastBadge = nil }
            }

        case .refreshHivemind:
            NotificationCenter.default.post(name: .refreshHivemind, object: nil)

        case .openFile(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))

        case .openURL(let urlString):
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)

        case .runShortcut(let name):
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            if let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") {
                NSWorkspace.shared.open(url)
            }

        case .copyToClipboard(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

        case .speak(let text, _):
            // Use NSSpeechSynthesizer via shell to avoid deprecation complexity
            let task = Process()
            task.launchPath = "/usr/bin/say"
            task.arguments = [text]
            try? task.run()
        }
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String, subtitle: String?, sound: Bool) {
        // osascript is permission-free and works on ad-hoc signed debug builds.
        // UNUserNotificationCenter requires entitlements that debug builds don't reliably carry.
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
