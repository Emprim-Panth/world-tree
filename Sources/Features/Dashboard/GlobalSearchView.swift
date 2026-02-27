import SwiftUI

/// Global search across messages, knowledge, archives, and graph nodes.
/// Opened via ⌘⇧F.
struct GlobalSearchView: View {
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var isSearching = false
    @State private var selectedSources: Set<GlobalSearchResult.Source> = Set(GlobalSearchResult.Source.allCases)
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isQueryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search everything…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isQueryFocused)
                    .onSubmit {
                        searchTask?.cancel()
                        searchTask = Task { await performSearch() }
                    }

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Source filter chips
            HStack(spacing: 6) {
                ForEach(GlobalSearchResult.Source.allCases, id: \.self) { source in
                    Button {
                        if selectedSources.contains(source) {
                            selectedSources.remove(source)
                        } else {
                            selectedSources.insert(source)
                        }
                    } label: {
                        Label(source.rawValue, systemImage: source.icon)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedSources.contains(source) ? .accentColor : .secondary)
                }
                Spacer()
                Text("\(filteredResults.count) results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Results
            if filteredResults.isEmpty && !query.isEmpty && !isSearching {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("No matches for \"\(query)\"")
                )
            } else {
                List(filteredResults) { result in
                    searchResultRow(result)
                }
                .listStyle(.inset)
            }
        }
        .onAppear { isQueryFocused = true }
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await performSearch()
            }
        }
    }

    private var filteredResults: [GlobalSearchResult] {
        results.filter { selectedSources.contains($0.source) }
    }

    private func performSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            results = try MessageStore.shared.searchAcrossAll(query: trimmed, limit: 60)
        } catch {
            wtLog("[GlobalSearch] Search failed: \(error)")
            results = []
        }
    }

    private func searchResultRow(_ result: GlobalSearchResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.source.icon)
                .font(.title3)
                .foregroundStyle(sourceColor(result.source))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if let project = result.project, !project.isEmpty {
                        Text(project)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    if let ts = result.timestamp {
                        Text(ts, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(result.title)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(result.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func sourceColor(_ source: GlobalSearchResult.Source) -> Color {
        switch source {
        case .message:   return .blue
        case .knowledge: return .purple
        case .archive:   return .green
        case .graph:     return .pink
        }
    }
}
