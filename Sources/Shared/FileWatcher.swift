import Foundation

/// Reusable file-system watcher backed by GCD dispatch sources.
/// Watches paths for specified events and invokes a handler on change.
final class FileWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    /// Watch a file or directory for changes.
    func watch(
        _ path: String,
        events: DispatchSource.FileSystemEvent = [.write, .rename, .delete],
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) {
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    /// Cancel all active watchers.
    func stopAll() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }

    deinit { stopAll() }
}
