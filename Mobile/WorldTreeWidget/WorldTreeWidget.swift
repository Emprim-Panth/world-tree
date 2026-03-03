import WidgetKit
import SwiftUI

// MARK: - Widget Entry (TASK-063)
//
// Shows the last message snippet from the most recently active branch.
// Data read from App Group UserDefaults (group.com.evanprimeau.worldtree),
// written by the main app whenever a message_complete event fires.

private enum WidgetKeys {
    static let suiteName = "group.com.evanprimeau.worldtree"
    static let lastMessage = "widget_lastMessage"
    static let lastTreeName = "widget_lastTreeName"
    static let lastBranchName = "widget_lastBranchName"
    static let lastUpdated = "widget_lastUpdated"
}

// MARK: - Timeline Entry

struct WorldTreeEntry: TimelineEntry {
    let date: Date
    let treeName: String
    let branchName: String?
    let snippet: String
    let lastUpdated: Date?
}

// MARK: - Timeline Provider

struct WorldTreeProvider: TimelineProvider {

    func placeholder(in context: Context) -> WorldTreeEntry {
        WorldTreeEntry(date: .now, treeName: "World Tree", branchName: "main", snippet: "Cortana is ready.", lastUpdated: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WorldTreeEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorldTreeEntry>) -> Void) {
        let entry = loadEntry()
        // Refresh every 30 minutes; the main app also calls WidgetCenter.reloadAllTimelines()
        // after each message_complete event, so this is just a safety backstop.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    private func loadEntry() -> WorldTreeEntry {
        let defaults = UserDefaults(suiteName: WidgetKeys.suiteName)
        let treeName   = defaults?.string(forKey: WidgetKeys.lastTreeName)   ?? "World Tree"
        let branchName = defaults?.string(forKey: WidgetKeys.lastBranchName)
        let snippet    = defaults?.string(forKey: WidgetKeys.lastMessage)    ?? "Open World Tree to start."
        let updated    = defaults?.object(forKey: WidgetKeys.lastUpdated) as? Date
        return WorldTreeEntry(date: .now, treeName: treeName, branchName: branchName, snippet: snippet, lastUpdated: updated)
    }
}

// MARK: - Widget View

struct WorldTreeWidgetView: View {
    let entry: WorldTreeEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallView(entry: entry)
        case .systemMedium:
            MediumView(entry: entry)
        default:
            SmallView(entry: entry)
        }
    }
}

private struct SmallView: View {
    let entry: WorldTreeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("World Tree", systemImage: "bubble.left.and.text.bubble.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.indigo)

            Spacer()

            Text(entry.snippet)
                .font(.caption)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let updated = entry.lastUpdated {
                Text(updated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

private struct MediumView: View {
    let entry: WorldTreeEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Branch context pill
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.treeName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let branch = entry.branchName,
                   !branch.isEmpty,
                   branch.lowercased() != "main" {
                    Text(branch)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let updated = entry.lastUpdated {
                    Text(updated, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 90)

            Divider()

            Text(entry.snippet)
                .font(.footnote)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }
}

// MARK: - Widget Declaration

struct WorldTreeWidgetConfiguration: Widget {
    let kind: String = "WorldTreeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorldTreeProvider()) { entry in
            WorldTreeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("World Tree")
        .description("See the latest message from your active branch.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
