import Foundation
import SQLite3
import Testing
@testable import LectureJockeyCore

/// Writes to a scratch database the way Wispr Flow does: one long-lived WAL
/// connection, rows inserted and sometimes filled in later.
final class FakeWispr {
    let dir: URL
    var path: String { dir.appendingPathComponent("flow.sqlite").path }
    private var db: OpaquePointer?

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try open()
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE History(transcriptEntityId TEXT PRIMARY KEY, asrText TEXT, formattedText TEXT,
              timestamp DATETIME, status TEXT, app TEXT, url TEXT, duration FLOAT)
            """)
        try insert("old", "from before the watcher started")
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dir)
    }

    func open() throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw WisprError.open("fake") }
    }

    /// Closing the last connection makes SQLite delete the WAL.
    func close() { sqlite3_close(db); db = nil }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WisprError.query(String(cString: sqlite3_errmsg(db)))
        }
    }

    func insert(_ id: String, _ text: String, status: String? = "formatted") throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let ts = f.string(from: Date()) + " +00:00"
        let st = status.map { "'\($0)'" } ?? "NULL"
        try exec("INSERT INTO History VALUES('\(id)', '', '\(text)', '\(ts)', \(st), 'com.google.Chrome', 'youtube.com', 1.5)")
    }
}

/// Collects dictations from the watcher's queue and lets the test wait for them.
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func add(_ d: Dictation) { lock.withLock { ids.append(d.id) } }
    func add(_ id: String) { lock.withLock { ids.append(id) } }

    /// Waits up to `timeout` for `id`; returns how long it took.
    func wait(for id: String, timeout: TimeInterval = 1) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if lock.withLock({ ids.contains(id) }) { return Date().timeIntervalSince(start) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    var all: [String] { lock.withLock { ids } }
}

@Suite(.serialized)
struct WatcherTests {
    @Test func deliversEachNewRowPromptlyWhileTheWriterStaysOpen() throws {
        let fake = try FakeWispr()
        let watcher = try Watcher(history: try WisprHistory(path: fake.path))
        let inbox = Inbox()
        watcher.start(onDictation: inbox.add)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        try fake.insert("a", "speed up 2x")
        let latency = try #require(inbox.wait(for: "a"))
        #expect(latency < 0.25)

        try fake.insert("b", "go back 30 seconds")
        #expect(inbox.wait(for: "b") != nil)
        #expect(inbox.all == ["a", "b"], "old rows are not replayed and each row arrives once")
    }

    @Test func picksUpARowWhoseTextArrivesLater() throws {
        let fake = try FakeWispr()
        let watcher = try Watcher(history: try WisprHistory(path: fake.path))
        let inbox = Inbox()
        watcher.start(onDictation: inbox.add)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        try fake.insert("late", "")
        #expect(inbox.wait(for: "late", timeout: 0.3) == nil, "an empty row is not delivered")
        try fake.exec("UPDATE History SET formattedText = 'pause' WHERE transcriptEntityId = 'late'")
        #expect(inbox.wait(for: "late") != nil)
    }

    @Test func survivesWalTruncateAndRecreate() throws {
        let fake = try FakeWispr()
        let watcher = try Watcher(history: try WisprHistory(path: fake.path))
        let inbox = Inbox()
        watcher.start(onDictation: inbox.add)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        try fake.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        try fake.insert("afterTruncate", "2x")
        #expect(inbox.wait(for: "afterTruncate") != nil)

        fake.close() // WAL file deleted
        Thread.sleep(forTimeInterval: 0.1)
        try fake.open() // WAL recreated on the next write
        try fake.insert("afterRecreate", "pause")
        #expect(inbox.wait(for: "afterRecreate") != nil)
    }

    @Test func reportsRecordingStartAndEnd() throws {
        let fake = try FakeWispr()
        let watcher = try Watcher(history: try WisprHistory(path: fake.path))
        let starts = Inbox(), ends = Inbox(), dictations = Inbox()
        watcher.onRecordingStart = { starts.add("start:" + $0) }
        watcher.onRecordingEnd = { ends.add("end:" + $0) }
        watcher.start(onDictation: dictations.add)
        defer { watcher.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        // Key pressed: Wispr inserts a row with no text and no status.
        try fake.insert("rec", "", status: nil)
        #expect(starts.wait(for: "start:rec") != nil)
        #expect(ends.all.isEmpty)
        // Done: text and status arrive.
        try fake.exec("UPDATE History SET formattedText = '2x', status = 'formatted' WHERE transcriptEntityId = 'rec'")
        #expect(ends.wait(for: "end:rec") != nil)
        #expect(dictations.wait(for: "rec") != nil)

        // A recording dismissed with no text still ends.
        try fake.insert("dismissed", "", status: nil)
        #expect(starts.wait(for: "start:dismissed") != nil)
        try fake.exec("UPDATE History SET status = 'dismissed' WHERE transcriptEntityId = 'dismissed'")
        #expect(ends.wait(for: "end:dismissed") != nil)
        #expect(starts.all == ["start:rec", "start:dismissed"], "each recording starts once")
    }
}
