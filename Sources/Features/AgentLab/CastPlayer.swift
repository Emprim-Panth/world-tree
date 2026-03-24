import SwiftUI

struct CastPlayer: View {
    let castPath: String
    @State private var outputLines: [String] = []
    @State private var isPlaying = false
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Controls
            HStack {
                Button(isPlaying ? "Stop" : "Play") { togglePlay() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Text(castPath.components(separatedBy: "/").last ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Clear") { outputLines = [] }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            // Output
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(outputLines.indices, id: \.self) { i in
                            Text(outputLines[i])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color.black)
                .onChange(of: outputLines.count) { _, _ in
                    if let last = outputLines.indices.last {
                        proxy.scrollTo(last)
                    }
                }
            }
        }
        .frame(minHeight: 200)
        .onDisappear {
            playTask?.cancel()
        }
    }

    private func togglePlay() {
        if isPlaying {
            playTask?.cancel()
            isPlaying = false
        } else {
            isPlaying = true
            playTask = Task { await playRecording() }
        }
    }

    private func playRecording() async {
        guard let content = try? String(contentsOfFile: castPath, encoding: .utf8) else {
            await MainActor.run {
                outputLines = ["[Error: could not read file at \(castPath)]"]
                isPlaying = false
            }
            return
        }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        await MainActor.run { outputLines = [] }

        // Skip header line (first line is JSON header)
        var lastTs: Double = 0
        for line in lines.dropFirst() {
            guard !Task.isCancelled else { break }
            guard let data = line.data(using: .utf8),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  arr.count >= 3,
                  let ts = arr[0] as? Double,
                  let eventType = arr[1] as? String,
                  eventType == "o",
                  let text = arr[2] as? String else { continue }

            let delay = ts - lastTs
            if delay > 0.01 && delay < 2.0 {
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 0.5) * 1_000_000_000))
            }
            lastTs = ts

            let segments = text.components(separatedBy: "\n")
            for segment in segments {
                let printable = segment.filter {
                    $0.isLetter || $0.isNumber || $0.isWhitespace ||
                    $0.isPunctuation || $0 == "/" || $0 == "." ||
                    $0 == "-" || $0 == "_" || $0 == "=" || $0 == ">" ||
                    $0 == "<" || $0 == "[" || $0 == "]" || $0 == "(" ||
                    $0 == ")" || $0 == "+" || $0 == "*" || $0 == "#"
                }
                let trimmed = printable.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    await MainActor.run { outputLines.append(trimmed) }
                }
            }
        }
        await MainActor.run { isPlaying = false }
    }
}
