import SwiftUI

// MARK: - Spatial Conversation View (TASK-066)
//
// A spatial-inspired presentation mode that surfaces the conversation as a
// floating glass panel — deepens the immersion on iPad and large iPhones.
//
// This does NOT require visionOS or Vision Pro.
// It uses standard SwiftUI materials (`.ultraThinMaterial`) and shadow layering
// to evoke a spatial/depth aesthetic on any device.
//
// Activated by: long-press on the branch title, or a "Spatial View" button in settings.
// Dismissed by: swipe down or the X button.

struct SpatialConversationView: View {
    @Environment(WorldTreeStore.self) private var store
    @Environment(ConnectionManager.self) private var connectionManager
    @AppStorage(Constants.UserDefaultsKeys.messageFontSize) private var fontSize = Constants.Defaults.messageFontSize

    @Binding var isPresented: Bool

    @State private var messageText = ""
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            // Blurred background scrim
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Floating glass panel
            VStack(spacing: 0) {
                // Drag handle
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.currentTree?.name ?? "World Tree")
                            .font(.headline)
                            .foregroundStyle(.white)
                        if let branch = store.currentBranch?.title, branch.lowercased() != "main" {
                            Text(branch)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Divider()
                    .background(Color.white.opacity(0.15))

                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.messages.suffix(40)) { message in
                                SpatialMessageRow(message: message, fontSize: fontSize)
                                    .id(message.id)
                            }
                            if store.isStreaming, !store.streamingText.isEmpty {
                                SpatialMessageRow(
                                    message: Message(
                                        id: "streaming",
                                        role: "assistant",
                                        content: store.streamingText,
                                        createdAt: ""
                                    ),
                                    fontSize: fontSize
                                )
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: store.messages.count) {
                        if let last = store.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                    .onChange(of: store.streamingText) {
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.15))

                // Input
                HStack(spacing: 12) {
                    TextField("Message Cortana…", text: $messageText, axis: .vertical)
                        .font(.system(size: fontSize))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .lineLimit(1...4)
                        .onSubmit { sendMessage() }

                    if store.isStreaming {
                        Button(action: stopStreaming) {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(messageText.isEmpty ? .white.opacity(0.3) : .white)
                        }
                        .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 28))
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.indigo.opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
            .frame(maxHeight: UIScreen.main.bounds.height * 0.75)
            .offset(y: max(0, dragOffset.height))
            .gesture(
                DragGesture()
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        if value.translation.height > 100 {
                            dismiss()
                        } else {
                            withAnimation(.spring) { dragOffset = .zero }
                        }
                    }
            )
        }
        .animation(.spring(duration: 0.4), value: isPresented)
    }

    private func sendMessage() {
        guard let branch = store.currentBranch,
              !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let content = messageText
        messageText = ""
        store.addOptimisticMessage(content: content)
        Task { await connectionManager.send(.sendMessage(branchId: branch.id, content: content)) }
    }

    private func stopStreaming() {
        guard let branch = store.currentBranch else { return }
        Task { await connectionManager.send(.cancelStream(branchId: branch.id)) }
    }

    private func dismiss() {
        withAnimation(.spring(duration: 0.35)) {
            isPresented = false
        }
    }
}

// MARK: - Spatial Message Row

private struct SpatialMessageRow: View {
    let message: Message
    let fontSize: Double

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            Text(message.content)
                .font(.system(size: fontSize))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    isUser
                        ? AnyShapeStyle(Color.indigo.opacity(0.7))
                        : AnyShapeStyle(Color.white.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .foregroundStyle(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(isUser ? 0 : 0.08), lineWidth: 1)
                )

            if !isUser { Spacer(minLength: 48) }
        }
    }
}
