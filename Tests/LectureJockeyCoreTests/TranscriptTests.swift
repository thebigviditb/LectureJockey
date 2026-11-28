import Foundation
import Testing
@testable import LectureJockeyCore

struct TranscriptTests {
    @Test func captionLinesEndWhereTheNextBeginsAndTheLastAtTheEnd() {
        let t = Transcript.fromCaptions(key: "youtube:x", title: "T", duration: 474.4, starts: [
            (7, "inside showing too much"), (0, "the moment that you feel"), (459, "all in this together"), (15, "  "),
        ])
        #expect(t.segments.map(\.start) == [0, 7, 459], "sorted, blank lines dropped")
        #expect(t.segments.map(\.end) == [7, 459, 474.4])
        #expect(t.covered == [[0, 474.4]])
        #expect(t.source == .youtube)
        #expect(t.wordCount == 13)
    }

    @Test func emptyCaptionsCoverNothing() {
        let t = Transcript.fromCaptions(key: "k", title: "", duration: 100, starts: [])
        #expect(t.segments.isEmpty)
        #expect(t.covered.isEmpty)
    }

    @Test func storeRoundTripsAndMakesSafeFileNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lj-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(directory: dir)
        let t = Transcript.fromCaptions(key: "youtube:oZDzd8jpGWc", title: "A talk", duration: 60, starts: [(0, "hi"), (30, "bye")])
        try store.save(t)
        #expect(store.url(for: t.key).lastPathComponent == "youtube_oZDzd8jpGWc.json")
        let loaded = try #require(store.load(t.key))
        #expect(loaded.segments == t.segments)
        #expect(loaded.title == "A talk")
        #expect(store.all().map(\.key) == ["youtube:oZDzd8jpGWc"])
        #expect(store.load("youtube:missing") == nil)
    }

    @Test(arguments: [
        ("https://www.youtube.com/watch?v=oZDzd8jpGWc", "oZDzd8jpGWc"),
        ("https://www.youtube.com/watch?v=jG5HeMTy1CU&t=42s&list=x", "jG5HeMTy1CU"),
        ("https://m.youtube.com/watch?v=abc", "abc"),
    ])
    func videoIDs(_ url: String, _ id: String) {
        #expect(YouTubeTranscript.videoID(from: url) == id)
    }

    @Test(arguments: ["https://www.youtube.com/", "https://www.youtube.com/results?search_query=x",
                      "https://toddvdating.com/watch?v=abc", "https://www.youtube.com/watch", "not a url"])
    func notVideos(_ url: String) {
        #expect(YouTubeTranscript.videoID(from: url) == nil)
    }
}

struct NowPlayingStreamTests {
    @Test func snapshotThenDiffs() {
        var state: [String: Any] = [:]
        NowPlayingStream.merge(line: Data(#"{"type":"data","diff":false,"payload":{"title":"A","playing":false,"bundleIdentifier":"com.google.Chrome"}}"#.utf8), into: &state)
        #expect(state["title"] as? String == "A")
        NowPlayingStream.merge(line: Data(#"{"type":"data","diff":true,"payload":{"playing":true}}"#.utf8), into: &state)
        #expect(state["playing"] as? Bool == true)
        #expect(state["title"] as? String == "A", "a diff keeps the other fields")
        NowPlayingStream.merge(line: Data(#"{"type":"data","diff":false,"payload":{"title":"B"}}"#.utf8), into: &state)
        #expect(state["playing"] == nil, "a snapshot replaces everything")
        NowPlayingStream.merge(line: Data("garbage".utf8), into: &state)
        #expect(state["title"] as? String == "B")
    }
}

struct AppleScriptTests {
    /// Regression: osascript was waited on before its output was read, so a result
    /// larger than the pipe buffer (a long transcript) blocked forever.
    @Test(.timeLimit(.minutes(1))) func readsOutputLargerThanThePipeBuffer() throws {
        let out = try AppleScript.run(#"""
            set s to "0123456789"
            repeat 15 times
                set s to s & s
            end repeat
            return s
            """#)
        #expect(out.count == 10 * 32768)
    }

    @Test func passesArgumentsWithoutSplicingThemIntoSource() throws {
        let tricky = #"he said "hi" \ end tell"#
        #expect(try AppleScript.run("on run argv\nreturn item 1 of argv\nend run", arguments: [tricky]) == tricky)
    }
}
