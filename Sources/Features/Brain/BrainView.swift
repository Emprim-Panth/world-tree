import SwiftUI

struct BrainView: View {
    @StateObject private var store = BrainStore.shared
    @State private var selectedDoc: BrainDocument?
    @State private var searchQuery = ""
    @State private var isEditing = false
    @State private var editContent = ""

    var displayedDocs: [BrainDocument] {
        searchQuery.isEmpty
            ? store.documents
            : store.search(query: searchQuery)
    }

    private func documents(in category: BrainCategory) -> [BrainDocument] {
        store.documents.filter { $0.category == category }
    }

    var body: some View {
        HSplitView {
            // Left: category + file list
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search brain...", text: $searchQuery)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                List(selection: $selectedDoc) {
                    if searchQuery.isEmpty {
                        ForEach(BrainCategory.allCases) { category in
                            Section(category.displayName) {
                                ForEach(documents(in: category)) { doc in
                                    BrainDocRow(doc: doc)
                                        .tag(doc)
                                }
                                Button {
                                    let newDoc = store.newDocument(in: category, title: "New Document")
                                    selectedDoc = newDoc
                                    isEditing = true
                                    editContent = newDoc.content
                                } label: {
                                    Label("New...", systemImage: "plus")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(displayedDocs) { doc in
                            BrainDocRow(doc: doc).tag(doc)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)

            // Right: document content
            if let doc = selectedDoc {
                VStack(alignment: .leading, spacing: 0) {
                    // Header bar
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).font(.headline)
                            Text(doc.category.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(isEditing ? "Done" : "Edit") {
                            if isEditing {
                                try? editContent.write(to: doc.id, atomically: true, encoding: .utf8)
                                isEditing = false
                                Task { await store.reload() }
                            } else {
                                editContent = doc.content
                                isEditing = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(Color(NSColor.windowBackgroundColor))

                    Divider()

                    if isEditing {
                        TextEditor(text: $editContent)
                            .font(.system(.body, design: .monospaced))
                            .padding(12)
                    } else {
                        ScrollView {
                            Text(doc.content)
                                .font(.system(.body, design: .default))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a Document",
                    systemImage: "brain",
                    description: Text("Choose a document from the brain library")
                )
            }
        }
        .onChange(of: selectedDoc) { _, doc in
            isEditing = false
            editContent = doc?.content ?? ""
        }
    }
}

struct BrainDocRow: View {
    let doc: BrainDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(doc.title).font(.body)
            Text(doc.lastModified, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
