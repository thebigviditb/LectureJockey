import Foundation

/// Hands each new Wispr Flow dictation to `onDictation` once, as Wispr writes it.
///
/// SQLite has no cross-process change notification, so this uses kqueue vnode
/// watches (DispatchSource):
///   - on the WAL and the database file: fire on every write, which is how a
///     commit lands while Wispr keeps the database open. (FSEvents does not
///     work here: it reports a write to a file only once the writer closes it,
///     and Wispr never does.)
///   - on the folder: fires when SQLite deletes or recreates the WAL, so the
///     file watches are reattached to the new file.
/// Between dictations nothing runs.
/// All mutable state is confined to `queue`.
public final class Watcher: @unchecked Sendable {
    public let history: WisprHistory
    /// Called on every write event, with the file name, before querying.
    public var onWrite: (@Sendable (String) -> Void)?
    /// Wispr added a row with no text or status: you pressed the key and it is recording.
    public var onRecordingStart: (@Sendable (String) -> Void)?
    /// That row got its text or a final status (formatted, dismissed, no_audio, ...).
    public var onRecordingEnd: (@Sendable (String) -> Void)?
    /// A row counts as a new recording only if it started this recently.
    public var recordingStartWindow: TimeInterval = 30

    private let queue = DispatchQueue(label: "lecturejockey.watcher")
    private let folder: String
    private let files: [String]
    private var folderSource: DispatchSourceFileSystemObject?
    private var fileSources: [String: (inode: UInt64, source: DispatchSourceFileSystemObject)] = [:]
    private var onDictation: ((Dictation) -> Void)?
    private var cursor: String
    private var seen: Set<String> = []
    private var recording: Set<String> = []

    public init(history: WisprHistory) throws {
        self.history = history
        folder = (history.path as NSString).deletingLastPathComponent
        let name = (history.path as NSString).lastPathComponent
        files = [name, name + "-wal"]
        cursor = try history.latestTimestamp()
        // Rows at the starting timestamp are old; never replay them.
        seen = Set(try history.dictations(since: cursor).map(\.id))
    }

    /// Starts listening and never returns. `onDictation` runs on a private serial queue.
    public func run(onDictation: @escaping @Sendable (Dictation) -> Void) -> Never {
        start(onDictation: onDictation)
        dispatchMain()
    }

    /// Starts listening and returns. `onDictation` runs on a private serial queue.
    public func start(onDictation: @escaping @Sendable (Dictation) -> Void) {
        queue.async {
            self.onDictation = onDictation
            self.folderSource = self.watch(self.folder, events: .write) { [weak self] _ in
                self?.attachFiles()
                self?.check()
            }
            self.attachFiles()
        }
    }

    public func stop() {
        queue.sync {
            folderSource?.cancel()
            fileSources.values.forEach { $0.source.cancel() }
            folderSource = nil
            fileSources = [:]
        }
    }

    // MARK: - Watches

    /// Watches each file whose inode changed (new WAL) or that is not watched yet.
    private func attachFiles() {
        for name in files {
            let path = (folder as NSString).appendingPathComponent(name)
            let inode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? UInt64) ?? nil
            if let current = fileSources[name], current.inode == inode { continue }
            fileSources[name]?.source.cancel()
            fileSources[name] = nil
            guard let inode else { continue }
            let source = watch(path, events: [.write, .extend, .delete, .rename]) { [weak self] event in
                guard let self else { return }
                if !event.isDisjoint(with: [.delete, .rename]) {
                    self.attachFiles()
                }
                self.onWrite?(name)
                self.check()
            }
            if let source { fileSources[name] = (inode, source) }
        }
    }

    private func watch(
        _ path: String,
        events: DispatchSource.FileSystemEvent,
        handler: @escaping (DispatchSource.FileSystemEvent) -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler { [weak source] in handler(source?.data ?? []) }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: - Reading

    private func check() {
        do {
            for d in try history.dictations(since: cursor) where !seen.contains(d.id) {
                if d.text.isEmpty {
                    if d.status.isEmpty {
                        // Recording in progress. Wispr leaves cancelled recordings like this forever,
                        // so only a fresh row counts as a start.
                        if !recording.contains(d.id), let date = d.date,
                           Date().timeIntervalSince(date) <= recordingStartWindow {
                            recording.insert(d.id)
                            onRecordingStart?(d.id)
                        }
                    } else if recording.remove(d.id) != nil {
                        // Finalized with no text (dismissed, no audio, error). Not marked seen,
                        // so text that arrives later is still delivered.
                        onRecordingEnd?(d.id)
                    }
                    continue
                }
                seen.insert(d.id)
                if recording.remove(d.id) != nil { onRecordingEnd?(d.id) }
                if d.timestamp > cursor { cursor = d.timestamp }
                onDictation?(d)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
    }
}
