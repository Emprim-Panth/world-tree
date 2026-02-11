import Foundation

/// Tails a daemon log file in real-time using DispatchSource.
/// Returns an AsyncStream of new lines as they're appended.
final class LogTailer {
    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        stop()
    }

    /// Start tailing the file, returning an AsyncStream of new lines
    func tail() -> AsyncStream<String> {
        AsyncStream { continuation in
            do {
                // Wait for file to exist
                let fm = FileManager.default
                if !fm.fileExists(atPath: fileURL.path) {
                    // Create empty file so we can watch it
                    fm.createFile(atPath: fileURL.path, contents: nil)
                }

                let handle = try FileHandle(forReadingFrom: fileURL)
                self.fileHandle = handle

                // Seek to end (only tail new content)
                handle.seekToEndOfFile()
                lastOffset = handle.offsetInFile

                // Create dispatch source watching for writes
                let fd = handle.fileDescriptor
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd,
                    eventMask: [.write, .extend],
                    queue: DispatchQueue.global(qos: .userInitiated)
                )

                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.readNewContent(handle: handle, continuation: continuation)
                }

                source.setCancelHandler {
                    try? handle.close()
                }

                self.source = source
                source.resume()

                continuation.onTermination = { [weak self] _ in
                    self?.stop()
                }
            } catch {
                continuation.yield("[LogTailer] Error: \(error.localizedDescription)")
                continuation.finish()
            }
        }
    }

    /// Read new content that was appended since last read
    private func readNewContent(handle: FileHandle, continuation: AsyncStream<String>.Continuation) {
        handle.seek(toFileOffset: lastOffset)
        let data = handle.readDataToEndOfFile()
        lastOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        // Split into lines and yield each
        let lines = text.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            continuation.yield(line)
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }
}
