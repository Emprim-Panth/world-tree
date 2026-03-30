import SwiftUI

/// Project card driven entirely from CompassState — no CachedProject, no ProjectActivity.
struct CompassProjectCard: View {
    let compassState: CompassState
    let ticketCount: Int
    let blockedCount: Int
    var onSelect: (() -> Void)?

    @State private var isExpanded = false
    @State private var isEditing = false
    @State private var editGoal = ""
    @State private var editPhase = ""
    @State private var newBlocker = ""
    @State private var isShowingRename = false
    @State private var renameText = ""
    @State private var isShowingDeleteConfirm = false
    @State private var isShowingArchiveConfirm = false
    @State private var fileError: String?

    @ObservedObject private var store = CompassStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            phaseAndGoal
            gitRow
            ticketRow
            blockerRow

            if isExpanded {
                expandedContent
            }
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(compassState.project) — tap to expand")
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        }
        .contextMenu {
            if let onSelect {
                Button("Open Project") { onSelect() }
            }
            Button("Resume in Terminal") {
                TerminalLauncher.shared.openTerminal(
                    projectName: compassState.project,
                    projectPath: compassState.path
                )
            }
            Divider()
            Button("Edit Project") { beginEditing() }
            Button("Reveal in Finder") {
                ProjectFileManager.shared.revealInFinder(
                    project: compassState.project, path: compassState.path)
            }
            Divider()
            Button("Rename…") {
                renameText = compassState.project
                isShowingRename = true
            }
            Button("Archive") { isShowingArchiveConfirm = true }
            Divider()
            Button("Move to Trash", role: .destructive) { isShowingDeleteConfirm = true }
        }
        .alert("Rename Project", isPresented: $isShowingRename) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                do {
                    try ProjectFileManager.shared.rename(
                        project: compassState.project, path: compassState.path, to: renameText)
                } catch { fileError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rename '\(compassState.project)' directory and update Compass.")
        }
        .confirmationDialog("Archive '\(compassState.project)'?",
                            isPresented: $isShowingArchiveConfirm, titleVisibility: .visible) {
            Button("Archive") {
                do {
                    try ProjectFileManager.shared.archive(
                        project: compassState.project, path: compassState.path)
                    store.refresh()
                } catch { fileError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves to ~/Development/Archives/. Recoverable.")
        }
        .confirmationDialog("Move '\(compassState.project)' to Trash?",
                            isPresented: $isShowingDeleteConfirm, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                do {
                    try ProjectFileManager.shared.trash(
                        project: compassState.project, path: compassState.path)
                    store.refresh()
                } catch { fileError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The project directory will be moved to Trash. You can recover it from there.")
        }
        .alert("File Operation Failed", isPresented: .init(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("OK") { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    // MARK: — Edit Mode

    private func beginEditing() {
        editGoal = compassState.currentGoal ?? ""
        editPhase = compassState.currentPhase ?? "unknown"
        newBlocker = ""
        withAnimation(.easeInOut(duration: 0.2)) {
            isExpanded = true
            isEditing = true
        }
    }

    private func saveEdits() {
        let name = compassState.project
        let trimmedGoal = editGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGoal != (compassState.currentGoal ?? "") {
            store.updateGoal(trimmedGoal, for: name)
        }
        if editPhase != (compassState.currentPhase ?? "unknown") {
            store.updatePhase(editPhase, for: name)
        }
        withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
    }

    // MARK: — Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .accessibilityLabel("Status: \(statusLabel)")

            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(compassState.project)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            Spacer()

            if isEditing {
                Button("Save") { saveEdits() }
                    .font(.system(size: 9, weight: .medium))
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) { isEditing = false }
                }
                .font(.system(size: 9, weight: .medium))
                .buttonStyle(.bordered).controlSize(.mini)
            } else if let phase = compassState.currentPhase, phase != "unknown" {
                Text(phase)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(phaseColor(phase))
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: — Goal & Phase

    @ViewBuilder
    private var phaseAndGoal: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Phase:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Picker("", selection: $editPhase) {
                        ForEach(CompassStore.phases, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.mini)
                }
                HStack(spacing: 4) {
                    Text("Goal:").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    TextField("Project goal...", text: $editGoal)
                        .font(.system(size: 10)).textFieldStyle(.roundedBorder).controlSize(.mini)
                        .onSubmit { saveEdits() }
                }
            }
        } else if let goal = compassState.currentGoal {
            Text(goal)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(2)
        }
    }

    // MARK: — Git

    private var gitRow: some View {
        HStack(spacing: 8) {
            if let branch = compassState.gitBranch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                    Text(branch).lineLimit(1)
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if compassState.isDirty {
                Text("\(compassState.gitUncommittedCount) uncommitted")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            Spacer()
            if let commit = compassState.gitLastCommit {
                Text(commit)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: 120, alignment: .trailing)
            }
        }
    }

    // MARK: — Tickets

    @ViewBuilder
    private var ticketRow: some View {
        if ticketCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "ticket").font(.system(size: 8)).foregroundStyle(.secondary)
                Text("\(ticketCount) open").font(.system(size: 9)).foregroundStyle(.secondary)
                if blockedCount > 0 {
                    Text("\(blockedCount) blocked")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.red)
                }
                Spacer()
                if let next = compassState.nextTicket {
                    Text("next: \(next)")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }

    // MARK: — Blockers

    @ViewBuilder
    private var blockerRow: some View {
        if !compassState.blockers.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(compassState.blockers, id: \.self) { blocker in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(.red)
                        Text(blocker)
                            .font(.system(size: 9)).foregroundStyle(.red.opacity(0.8)).lineLimit(1)
                        if isEditing {
                            Spacer()
                            Button {
                                store.removeBlocker(blocker, for: compassState.project)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10)).foregroundStyle(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: — Expanded Content

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            if isEditing {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle").font(.system(size: 9)).foregroundStyle(.red.opacity(0.6))
                    TextField("Add blocker...", text: $newBlocker)
                        .font(.system(size: 9)).textFieldStyle(.roundedBorder).controlSize(.mini)
                        .onSubmit {
                            store.addBlocker(newBlocker, for: compassState.project)
                            newBlocker = ""
                        }
                    Button("Add") {
                        store.addBlocker(newBlocker, for: compassState.project)
                        newBlocker = ""
                    }
                    .font(.system(size: 9)).controlSize(.mini)
                    .disabled(newBlocker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !compassState.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                        Text("Decisions").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(compassState.decisions.prefix(3), id: \.self) { decision in
                        Text("• \(decision)")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if compassState.decisions.count > 3 {
                        Text("+\(compassState.decisions.count - 3) more")
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }

            if let summary = compassState.lastSessionSummary {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 8)).foregroundStyle(.tertiary)
                    Text(summary)
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
    }

    // MARK: — Styling

    private var statusColor: Color {
        if !compassState.blockers.isEmpty { return Palette.blocked }
        if compassState.isDirty { return Palette.dirty }
        return Palette.neutral.opacity(0.4)
    }

    private var statusLabel: String {
        if !compassState.blockers.isEmpty { return "blocked" }
        if compassState.isDirty { return "modified" }
        return "inactive"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8).fill(cardFillColor)
    }

    private var cardFillColor: Color {
        if !compassState.blockers.isEmpty { return Color.red.opacity(0.06) }
        return Palette.cardBackground.opacity(0.5)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        if !compassState.blockers.isEmpty { return .red.opacity(0.3) }
        return .clear
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "implementing": return .blue
        case "debugging": return .orange
        case "testing": return .purple
        case "shipping": return .green
        case "planning": return .cyan
        case "exploring": return .indigo
        default: return .gray
        }
    }
}
