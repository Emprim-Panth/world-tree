import SwiftUI
import CoreGraphics

// MARK: - PencilDiffView

/// Side-by-side visual comparison: Pencil design frame vs the running app.
///
/// Pencil screenshot comes from PencilConnectionStore.getFrameScreenshot.
/// App screenshot is captured from the frontmost on-screen window that doesn't
/// belong to World Tree, using CGWindowListCreateImage.
struct PencilDiffView: View {
    let frame: PencilNode

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pencil = PencilConnectionStore.shared

    @State private var pencilImage: NSImage?
    @State private var appImage: NSImage?
    @State private var isLoading = true
    @State private var pencilError: String?
    @State private var appError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Capturing screenshots…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        imagePanel(
                            label: "Design (Pencil)",
                            image: pencilImage,
                            error: pencilError,
                            tint: .blue
                        )
                        imagePanel(
                            label: "App (Running)",
                            image: appImage,
                            error: appError,
                            tint: .green
                        )
                    }
                }
            }
            .navigationTitle("Compare: \(frame.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isLoading = true
                        pencilImage = nil
                        appImage = nil
                        pencilError = nil
                        appError = nil
                        Task { await loadImages() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .task { await loadImages() }
    }

    // MARK: - Image Panel

    @ViewBuilder
    private func imagePanel(label: String, image: NSImage?, error: String?, tint: Color) -> some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)

            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(tint.opacity(0.3), lineWidth: 1)
                    )

                Text("\(Int(img.size.width)) × \(Int(img.size.height))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else if let err = error {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            } else {
                Color.primary.opacity(0.04)
                    .cornerRadius(6)
                    .overlay(
                        Text("No image")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .padding(12)
        .frame(minWidth: 300, minHeight: 400)
    }

    // MARK: - Load Images

    private func loadImages() async {
        isLoading = true
        defer { isLoading = false }

        // Pencil screenshot
        do {
            pencil.invalidateScreenshotCache(for: frame.id)
            let data = try await pencil.getFrameScreenshot(frameId: frame.id)
            pencilImage = NSImage(data: data)
            if pencilImage == nil { pencilError = "Invalid image data from Pencil" }
        } catch {
            pencilError = "Pencil: \(error.localizedDescription)"
        }

        // App screenshot (frontmost non-World-Tree window)
        let captured = captureAppWindow()
        if let img = captured {
            appImage = img
        } else {
            appError = "No app window found — run your app in Simulator or on device"
        }
    }

    // MARK: - CGWindowList App Capture

    /// Captures the frontmost on-screen window not belonging to World Tree.
    /// Requires Screen Recording permission (already granted to World Tree).
    private func captureAppWindow() -> NSImage? {
        guard let cfList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ), let infoList = cfList as NSArray as? [[String: Any]] else { return nil }

        let ourPID = ProcessInfo.processInfo.processIdentifier

        // Find the first normal-layer window from another process
        guard let windowInfo = infoList.first(where: {
            guard let pid = $0[kCGWindowOwnerPID as String] as? Int32,
                  let layer = $0[kCGWindowLayer as String] as? Int else { return false }
            return pid != ourPID && layer == 0
        }) else { return nil }

        guard let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else { return nil }

        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let bounds = CGRect(
            x: boundsDict["X"] ?? 0,
            y: boundsDict["Y"] ?? 0,
            width: boundsDict["Width"] ?? 1,
            height: boundsDict["Height"] ?? 1
        )
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        guard let cgImage = CGWindowListCreateImage(
            bounds,
            .optionIncludingWindow,
            windowID,
            .bestResolution
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
    }
}
