import Foundation
import SQLite3

/// One dictation as Wispr Flow recorded it.
public struct Dictation: Sendable, Equatable {
    public let id: String
    /// As stored, e.g. "2026-11-27 18:40:21.915 +00:00" (UTC).
    public let timestamp: String
    /// Bundle ID of the app Wispr typed into, e.g. "com.google.Chrome".
    public let app: String
    /// The tab's domain for browser dictations, else "unknown" or empty.
    public let url: String
    public let text: String
    public let status: String

    public var date: Date? { WisprHistory.parseTimestamp(timestamp) }
}

/// Read-only access to Wispr Flow's local history database.
///
/// The schema is undocumented and may change with a Wispr update, so every
/// read of it lives here. LectureJockey never writes to this file.
public final class WisprHistory {
    public static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite").path

    public let path: String
    private var db: OpaquePointer?

    public init(path: String = WisprHistory.defaultPath) throws {
        self.path = path
        let uri = "file:\(path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw WisprError.open(msg)
        }
        sqlite3_busy_timeout(db, 1000)
    }

    deinit { sqlite3_close(db) }

    /// The newest timestamp in the table, used as the starting cursor so the
    /// watcher never replays old dictations.
    public func latestTimestamp() throws -> String {
        try query("SELECT COALESCE(MAX(timestamp), '') FROM History") { stmt in
            column(stmt, 0)
        }.first ?? ""
    }

    /// Dictations at or after `timestamp`, oldest first. Callers dedupe by id,
    /// because Wispr may update a row (raw transcript, then formatted).
    public func dictations(since timestamp: String) throws -> [Dictation] {
        let sql = """
            SELECT transcriptEntityId, timestamp, COALESCE(app, ''), COALESCE(url, ''),
                   COALESCE(NULLIF(formattedText, ''), NULLIF(asrText, ''), ''), COALESCE(status, '')
            FROM History WHERE timestamp >= ? ORDER BY timestamp ASC
            """
        return try query(sql, bind: [timestamp]) { stmt in
            Dictation(
                id: column(stmt, 0), timestamp: column(stmt, 1), app: column(stmt, 2),
                url: column(stmt, 3), text: column(stmt, 4), status: column(stmt, 5)
            )
        }
    }

    // MARK: - SQLite helpers

    private func query<T>(_ sql: String, bind: [String] = [], row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw WisprError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, transient)
        }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { rows.append(row(stmt)); continue }
            if rc == SQLITE_DONE { break }
            throw WisprError.query(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private func column(_ stmt: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }

    // MARK: - Timestamps

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS xxx"
        return f
    }()

    public static func parseTimestamp(_ s: String) -> Date? { formatter.date(from: s) }
}

public enum WisprError: Error, CustomStringConvertible {
    case open(String)
    case query(String)

    public var description: String {
        switch self {
        case .open(let m): return "cannot open Wispr Flow history: \(m)"
        case .query(let m): return "Wispr Flow history query failed: \(m)"
        }
    }
}
