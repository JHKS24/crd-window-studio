import Foundation

/// Calls `onChange` when the configuration file's contents change.
/// File events catch in-place edits; directory events rebind atomic replacements.
/// A watch on the nearest existing ancestor survives removal and recreation of the configuration directory.
final class ConfigurationWatcher {
    private let file: URL
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var lastSignature: String?
    private var pending: DispatchWorkItem?
    init(file: URL, onChange: @escaping () -> Void) {
        self.file = file
        self.onChange = onChange
        lastSignature = signature(file.path)
        rearm()
    }
    /// Device, inode, size and times of `path`; nil when it does not exist.
    private func signature(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec):\(info.st_ctimespec)"
    }
    /// Watches the file, its directory and the nearest existing ancestor, replacing any watch whose
    /// path now points at a different file.
    private func rearm() {
        let directory = file.deletingLastPathComponent()
        var ancestor = directory.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        let paths = Set([file.path, directory.path, ancestor.path])
        for path in Array(sources.keys) {
            var current = stat(), watched = stat()
            let source = sources[path]!
            if !paths.contains(path) || stat(path, &current) != 0 || fstat(source.handle, &watched) != 0 ||
                current.st_ino != watched.st_ino || current.st_dev != watched.st_dev {
                source.cancel()
                sources.removeValue(forKey: path)
            }
        }
        for path in paths where sources[path] == nil {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            sources[path] = source
            source.resume()
        }
    }
    /// Re-arms the watches and, when the file's signature changed, calls `onChange` after 80 ms.
    private func changed() {
        rearm()
        let next = signature(file.path)
        guard next != lastSignature else { return }
        lastSignature = next
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80), execute: work)
    }
    deinit {
        pending?.cancel()
        sources.values.forEach { $0.cancel() }
    }
}
