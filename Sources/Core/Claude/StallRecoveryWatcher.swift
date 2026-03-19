import Foundation
import SwiftUI

// MARK: - Stall Recovery Watcher

/// Polls ~/.cortana/worldtree/stall-recovery.json written by cortana-session-watchdog.
///
/// When a stall is detected (no Claude output for 20min, user idle 3min),
/// the watchdog writes the signal file. This class reads it and surfaces
/// a recovery offer to the user — without auto-recovering if they might be typing.
///
/// Grace window: if the user has typed in the last 3 minutes, the banner is suppressed.
@MainActor
final class StallRecoveryWatcher: ObservableObject {
    static let shared = StallRecoveryWatcher()

    @Published private(set) var isStallDetected: Bool = false
    @Published private(set) var stalledSessionId: String?
    @Published private(set) var stallDetectedAt: Date?

    private let signalPath: String
    private let lastUserInputPath: String
    private var timer: Timer?

    /// How long since last user input before we show the recovery banner.
    private let gracePeriod: TimeInterval = 3 * 60  // 3 minutes

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        signalPath      = "\(home)/.cortana/worldtree/stall-recovery.json"
        lastUserInputPath = "\(home)/.cortana/worldtree/last-user-input.json"
    }

    func startMonitoring() {
        guard timer == nil else { return }
        // Poll every 2min — matches watchdog interval
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForStall() }
        }
        // Also check on startup
        checkForStall()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func dismiss() {
        isStallDetected = false
        stalledSessionId = nil
        stallDetectedAt = nil
        // Clear the signal so we don't resurface it
        clearSignal()
    }

    // MARK: - Private

    private func checkForStall() {
        guard FileManager.default.fileExists(atPath: signalPath) else {
            if isStallDetected { isStallDetected = false }
            return
        }

        guard let data = FileManager.default.contents(atPath: signalPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cleared = json["cleared"] as? Bool, !cleared,
              let detectedAtMs = json["detectedAt"] as? TimeInterval
        else {
            // Cleared or malformed signal
            if isStallDetected { isStallDetected = false }
            return
        }

        // Check grace window — don't show banner if user typed recently
        let sinceInput = lastUserInputAge()
        if sinceInput < gracePeriod {
            // User is active — suppress banner, clear signal
            clearSignal()
            return
        }

        // Surface the banner
        let sessionId = json["sessionId"] as? String
        let detectedAt = Date(timeIntervalSince1970: detectedAtMs / 1000)

        isStallDetected = true
        stalledSessionId = sessionId
        stallDetectedAt = detectedAt
    }

    private func lastUserInputAge() -> TimeInterval {
        guard let data = FileManager.default.contents(atPath: lastUserInputPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ts = json["timestamp"] as? TimeInterval
        else { return .infinity }
        return Date().timeIntervalSince1970 - ts / 1000
    }

    private func clearSignal() {
        let cleared = "{\"cleared\":true,\"clearedAt\":\(Int(Date().timeIntervalSince1970 * 1000))}"
        try? cleared.write(toFile: signalPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Stall Recovery Banner

/// Shows a subtle banner at the top of the conversation when a stall is detected.
/// Offers "Retry" (sends a wake message) and "Dismiss" options.
struct StallRecoveryBanner: View {
    @ObservedObject private var watcher = StallRecoveryWatcher.shared
    let onRetry: () -> Void

    private var timeAgo: String {
        guard let date = watcher.stallDetectedAt else { return "" }
        let diff = Int(Date().timeIntervalSince(date))
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(diff / 60)m ago" }
        return "\(diff / 3600)h ago"
    }

    var body: some View {
        if watcher.isStallDetected {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Session may have stalled")
                        .font(.system(size: 12, weight: .semibold))
                    Text("No response detected\(timeAgo.isEmpty ? "" : " · \(timeAgo)"). Claude may still be running a long tool chain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Retry") {
                    watcher.dismiss()
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)

                Button {
                    watcher.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.08))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(Color.orange.opacity(0.2)),
                alignment: .bottom
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
