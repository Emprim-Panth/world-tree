import SwiftUI

/// Unified brain panel — combines per-project BRAIN.md editing with central brain viewing.
/// Replaces the old separate "Brain" and "Central Brain" panels.
struct UnifiedBrainView: View {
    @State private var mode: BrainMode = .central

    enum BrainMode: String, CaseIterable {
        case central = "Central Brain"
        case projects = "Project Brain"
    }

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            switch mode {
            case .central:
                CentralBrainView()
            case .projects:
                BrainEditorView()
            }
        }
    }

    private var modePicker: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(BrainMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.cardBackground.opacity(0.3))
    }
}
