import SwiftUI

/// Interactive decision-tree choice block.
///
/// Rendered when the assistant outputs a ```choices code fence.
/// Format:
/// ```choices
/// Question text here
/// - Option A
/// - Option B
/// - Option C
/// ```
///
/// Renders a vis-network hierarchical tree — nodes are draggable and
/// double-clickable for inline editing. Tapping an option fires it as
/// an auto-submitted user message. Locked after selection.
struct ChoiceBlockView: View {

    let raw: String

    @State private var renderedHeight: CGFloat = 300

    var body: some View {
        ArtifactRendererView(content: raw, mode: .choiceTree, renderedHeight: $renderedHeight)
            .frame(height: renderedHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// choiceSelected notification is defined in ArtifactRendererView.swift
