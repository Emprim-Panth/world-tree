import SwiftUI

// MARK: - Tool Execution Timeline

/// Expandable timeline showing all tool calls with durations for a branch.
/// Each entry shows tool name, status, duration, and truncated result.
struct ToolTimeline: View {
    let events: [CanvasEvent]
    @State private var isExpanded = false

    /// Pair up toolStart + toolEnd events to compute durations.
    private var toolPairs: [ToolPair] {
        var starts: [Date] = []
        var pairs: [ToolPair] = []

        for event in events {
            switch event.eventType {
            case .toolStart:
                starts.append(event.timestamp)
                let name = extractName(from: event.eventData)
                pairs.append(ToolPair(
                    name: name,
                    startTime: event.timestamp,
                    endTime: nil,
                    status: .running,
                    result: nil
                ))

            case .toolEnd:
                let name = extractName(from: event.eventData)
                if let idx = pairs.lastIndex(where: { $0.name == name && $0.status == .running }) {
                    pairs[idx].endTime = event.timestamp
                    pairs[idx].status = .completed
                    pairs[idx].result = extractResult(from: event.eventData)
                }

            case .toolError:
                let name = extractName(from: event.eventData)
                if let idx = pairs.lastIndex(where: { $0.name == name && $0.status == .running }) {
                    pairs[idx].endTime = event.timestamp
                    pairs[idx].status = .failed
                    pairs[idx].result = extractResult(from: event.eventData)
                }

            default:
                break
            }
        }

        return pairs
    }

    var body: some View {
        if !events.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(toolPairs.enumerated()), id: \.offset) { _, pair in
                        ToolPairRow(pair: pair)
                    }
                }
                .padding(.leading, 8)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))

                    Text("Tool Timeline")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text("(\(toolPairs.count))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractName(from jsonStr: String?) -> String {
        guard let str = jsonStr,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            return "unknown"
        }
        return name
    }

    private func extractResult(from jsonStr: String?) -> String? {
        guard let str = jsonStr,
              let data = str.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? String else {
            return nil
        }
        return result
    }
}

// MARK: - Tool Pair Model

struct ToolPair {
    let name: String
    let startTime: Date
    var endTime: Date?
    var status: ToolPairStatus
    var result: String?

    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    var durationText: String {
        guard let dur = duration else { return "running..." }
        if dur < 1 { return String(format: "%.0fms", dur * 1000) }
        if dur < 60 { return String(format: "%.1fs", dur) }
        return String(format: "%.0fm %.0fs", dur / 60, dur.truncatingRemainder(dividingBy: 60))
    }
}

enum ToolPairStatus {
    case running, completed, failed

    var icon: String {
        switch self {
        case .running: return "arrow.trianglehead.clockwise"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Tool Pair Row

struct ToolPairRow: View {
    let pair: ToolPair

    private var screenshotPath: String? {
        guard pair.name == "capture_screenshot",
              let result = pair.result,
              let match = result.range(of: #"(/[^\s]+\.png)"#, options: .regularExpression) else {
            return nil
        }
        return String(result[match])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: pair.status.icon)
                    .foregroundColor(pair.status.color)
                    .font(.system(size: 9))

                Text(pair.name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)

                Spacer()

                Text(pair.durationText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

            if let path = screenshotPath {
                ScreenshotThumbnail(path: path)
            }
        }
    }
}

// MARK: - Screenshot Thumbnail

struct ScreenshotThumbnail: View {
    let path: String
    @State private var image: NSImage?
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let img = image {
                VStack(alignment: .leading, spacing: 2) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: isExpanded ? 500 : 240)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                        .onTapGesture { isExpanded.toggle() }
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    Text(isExpanded ? "Tap to collapse" : "Tap to expand")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.leading, 16)
            }
        }
        .onAppear {
            Task {
                let img = NSImage(contentsOfFile: path)
                await MainActor.run { self.image = img }
            }
        }
    }
}
