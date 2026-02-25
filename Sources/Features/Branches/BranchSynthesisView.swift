import SwiftUI

/// Sheet that reads messages from sibling branches and fires a structured
/// synthesis prompt into a new branch — letting Claude combine the best
/// of multiple exploration paths into a single recommendation.
struct BranchSynthesisView: View {
    let treeId: String
    let allBranches: [Branch]
    let currentBranchId: String
    let onCreated: (String) -> Void

    @State private var selectedBranchIds: Set<String> = []
    @State private var focusInstruction = ""
    @State private var isSynthesizing = false
    @State private var error: String?

    var candidateBranches: [Branch] {
        allBranches.filter { $0.id != currentBranchId && $0.messageCount > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "arrow.triangle.merge")
                    .foregroundStyle(.purple)
                Text("Synthesize Branches")
                    .font(.headline)
            }

            Text("Select the branches to synthesize. I'll read each one and produce a unified recommendation.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            // Branch picker
            if candidateBranches.isEmpty {
                Text("No other branches with messages to synthesize.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(candidateBranches) { branch in
                            HStack(spacing: 10) {
                                Image(systemName: selectedBranchIds.contains(branch.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedBranchIds.contains(branch.id) ? .purple : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(branch.displayTitle)
                                        .font(.callout)
                                        .fontWeight(.medium)
                                    HStack(spacing: 6) {
                                        Label(branch.branchType.rawValue.capitalized,
                                              systemImage: branchTypeIcon(branch.branchType))
                                        Text("·")
                                        Text("\(branch.messageCount) messages")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(selectedBranchIds.contains(branch.id)
                                        ? Color.purple.opacity(0.08)
                                        : Color.primary.opacity(0.04))
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedBranchIds.contains(branch.id) {
                                    selectedBranchIds.remove(branch.id)
                                } else {
                                    selectedBranchIds.insert(branch.id)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            // Optional focus instruction
            VStack(alignment: .leading, spacing: 6) {
                Text("Focus instruction (optional)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TextField("e.g. prioritize performance over simplicity", text: $focusInstruction)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Actions
            HStack {
                Button("Cancel") { onCreated("") }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Text("\(selectedBranchIds.count) branch\(selectedBranchIds.count == 1 ? "" : "es") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(isSynthesizing ? "Synthesizing…" : "Synthesize") {
                    synthesize()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBranchIds.count < 2 || isSynthesizing)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // Pre-select all candidate branches
            selectedBranchIds = Set(candidateBranches.map(\.id))
        }
    }

    private func synthesize() {
        guard let currentBranch = allBranches.first(where: { $0.id == currentBranchId }) else { return }
        isSynthesizing = true
        error = nil

        Task {
            do {
                let newBranch = try await SynthesisService.createSynthesisBranch(
                    treeId: treeId,
                    parentBranch: currentBranch,
                    selectedBranchIds: Array(selectedBranchIds),
                    allBranches: allBranches,
                    focusInstruction: focusInstruction.isEmpty ? nil : focusInstruction
                )
                await MainActor.run {
                    isSynthesizing = false
                    onCreated(newBranch.id)
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isSynthesizing = false
                }
            }
        }
    }

    private func branchTypeIcon(_ type: BranchType) -> String {
        switch type {
        case .conversation: return "bubble.left"
        case .implementation: return "gearshape"
        case .exploration: return "magnifyingglass"
        }
    }
}
