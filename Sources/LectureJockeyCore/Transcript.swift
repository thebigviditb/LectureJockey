import Foundation

/// A timed transcript of one video, in video time (seconds from the start), not
/// wall-clock time. One file per video. Captions fill it whole; live transcription
/// (later) fills the parts you watched and records them in `covered`.
public struct Transcript: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public enum Source: String, Codable, Sendable {
        /// YouTube's own transcript (often its auto-generated captions).
        case youtube
        /// Transcribed on this Mac while you watched.
        case live
    }

    /// Stable per video: "youtube:<id>", later "embed:<url>" or "nowplaying:<title>|<duration>".
    public var key: String
    public var title: String
    public var duration: Double
    public var source: Source
    public var segments: [Segment]
    /// Stretches of the video the segments cover, merged and sorted.
    public var covered: [[Double]]
    public var updatedAt: Date

    public init(key: String, title: String, duration: Double, source: Source, segments: [Segment], covered: [[Double]], updatedAt: Date = Date()) {
        self.key = key
        self.title = title
        self.duration = duration
        self.source = source
        self.segments = segments
        self.covered = covered
        self.updatedAt = updatedAt
    }

    /// Builds a complete transcript from caption lines that only carry start times:
    /// each line ends where the next starts, the last at the video's end.
    public static func fromCaptions(key: String, title: String, duration: Double, starts: [(Double, String)]) -> Transcript {
        let lines = starts
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.0 < $1.0 }
        var segments: [Segment] = []
        for (i, line) in lines.enumerated() {
            let next = i + 1 < lines.count ? lines[i + 1].0 : max(duration, line.0)
            segments.append(Segment(start: line.0, end: max(line.0, next), text: line.1))
        }
        let covered: [[Double]] = segments.isEmpty ? [] : [[0, max(duration, segments.last!.end)]]
        return Transcript(key: key, title: title, duration: duration, source: .youtube, segments: segments, covered: covered)
    }

    public var wordCount: Int { segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }
}

/// Transcripts on disk, one JSON file per video in
/// ~/Library/Application Support/LectureJockey/transcripts/.
public struct TranscriptStore: Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LectureJockey/transcripts", isDirectory: true)

    public let directory: URL

    public init(directory: URL = TranscriptStore.defaultDirectory) {
        self.directory = directory
    }

    /// File name for a key; keys contain ":" and "/" so they are made filename-safe.
    public func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    public func load(_ key: String) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    public func save(_ t: Transcript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(t).write(to: url(for: t.key), options: .atomic)
    }

    public func all() -> [Transcript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { load(String($0.deletingPathExtension().lastPathComponent)) ?? decodeFile($0) }
    }

    private func decodeFile(_ url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }
}
