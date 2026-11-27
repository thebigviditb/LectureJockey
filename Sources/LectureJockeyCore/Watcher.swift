import Foundation

/// Watches Wispr Flow's database for new dictations and hands each one to
/// `onDictation` once.
///
/// It polls the modification time and size of the database and its WAL every
/// `interval` and queries only when they change. Polling a stat() is cheap and,
/// unlike a file-descriptor watch, survives Wispr truncating or replacing the
/// WAL on a checkpoint.
public final class Watcher {
    public let history: WisprHistory
    public let interval: TimeInterval
    private var cursor: String
    private var seen: Set<String> = []
    private var lastSignature = ""

    public init(history: WisprHistory, interval: TimeInterval = 0.2) throws {
        self.history = history
        self.interval = interval
        self.cursor = try history.latestTimestamp()
        // Rows at the starting timestamp are old; never replay them.
        seen = Set(try history.dictations(since: cursor).map(\.id))
        lastSignature = signature()
    }

    public func run(onDictation: (Dictation) -> Void) -> Never {
        while true {
            Thread.sleep(forTimeInterval: interval)
            let sig = signature()
            guard sig != lastSignature else { continue }
            lastSignature = sig
            do {
                for d in try history.dictations(since: cursor) where !seen.contains(d.id) {
                    // Wispr can insert a row before the text is ready; pick it up on a later change.
                    guard !d.text.isEmpty else { continue }
                    seen.insert(d.id)
                    if d.timestamp > cursor { cursor = d.timestamp }
                    onDictation(d)
                }
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
        }
    }

    private func signature() -> String {
        [history.path, history.path + "-wal"].map { p in
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = a?[.size] as? Int ?? 0
            return "\(m):\(s)"
        }.joined(separator: "|")
    }
}
