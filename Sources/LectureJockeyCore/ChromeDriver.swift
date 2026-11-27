import Foundation

/// Controls the `<video>` in Chrome's front tab by running JavaScript through
/// AppleScript. Needs Chrome's View > Developer > "Allow JavaScript from Apple
/// Events", and macOS Automation permission for the process running this.
///
/// The JavaScript is built from numbers only, never from dictated text.
public struct ChromeDriver: Sendable {
    public static let bundleID = "com.google.Chrome"

    public init() {}

    /// State of the video the driver would act on, or nil if the tab has none.
    public struct VideoState: Sendable, Equatable {
        public let playing: Bool
        public let rate: Double
        public let time: Double
        public let duration: Double
        /// Tag of the focused element, to see where Wispr's paste landed.
        public let activeElement: String
    }

    // Picks the playing video, else the largest one on the page.
    private static let pick = """
        const vs = Array.from(document.querySelectorAll('video'));
        const v = vs.find(x => !x.paused && !x.ended && x.readyState > 2)
          || vs.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
        """

    private static let report = """
        const ae = document.activeElement;
        const el = ae ? ae.tagName.toLowerCase() + (ae.isContentEditable ? '[editable]' : '') : '';
        return JSON.stringify(v ? {p: !v.paused && !v.ended, r: v.playbackRate, t: v.currentTime,
          d: isFinite(v.duration) ? v.duration : 0, a: el} : null);
        """

    public func state() throws -> VideoState? {
        try run("")
    }

    /// Applies `command` and returns the video's state afterwards.
    @discardableResult
    public func apply(_ command: Command) throws -> VideoState? {
        let js: String
        switch command {
        case .setRate(let r):
            js = "v.playbackRate = \(clampRate(r));"
        case .changeRate(let d):
            js = "v.playbackRate = Math.min(4, Math.max(0.25, Math.round((v.playbackRate + \(d)) * 100) / 100));"
        case .seek(let s):
            js = "v.currentTime = Math.max(0, Math.min(isFinite(v.duration) ? v.duration : Infinity, v.currentTime + \(s)));"
        case .seekTo(let s):
            js = "v.currentTime = Math.max(0, Math.min(isFinite(v.duration) ? v.duration : Infinity, \(s)));"
        case .seekToFraction(let f):
            js = "if (isFinite(v.duration)) v.currentTime = Math.max(0, Math.min(v.duration - 0.5, v.duration * \(f)));"
        case .pause:
            js = "v.pause();"
        case .play:
            js = "v.play();"
        }
        return try run(js)
    }

    private func clampRate(_ r: Double) -> Double { min(4, max(0.25, r)) }

    private func run(_ action: String) throws -> VideoState? {
        let js = "(() => { \(Self.pick) if (v) { \(action) } \(Self.report) })()"
        let script = """
            tell application id "\(Self.bundleID)"
                if (count of windows) = 0 then return "null"
                execute active tab of front window javascript \(appleScriptString(js))
            end tell
            """
        let out = try AppleScript.run(script)
        guard let data = out.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any]
        else { return nil }
        return VideoState(
            playing: obj["p"] as? Bool ?? false,
            rate: obj["r"] as? Double ?? 1,
            time: obj["t"] as? Double ?? 0,
            duration: obj["d"] as? Double ?? 0,
            activeElement: obj["a"] as? String ?? ""
        )
    }

    // MARK: - Ducking

    /// Lowers the playing, unmuted video in the front tab to `level` if it is
    /// louder. The previous volume is kept on the element (data-lj-volume), so a
    /// restore works even after LectureJockey restarts.
    public enum DuckResult: Sendable, Equatable {
        case ducked(DuckToken)
        /// The video is paused, muted or already at or below the level.
        case notNeeded
        /// No video the page's JavaScript can reach, e.g. a player embedded from another domain.
        case noReachableVideo
    }

    public func duck(to level: Double) throws -> DuckResult {
        let js = """
            (() => { \(Self.pick)
              if (!v) return 'none';
              if (v.paused || v.ended || v.muted || v.volume <= \(level)) return '';
              const prev = v.volume;
              v.dataset.ljVolume = String(prev);
              v.volume = \(level);
              return String(prev);
            })()
            """
        let script = """
            tell application id "\(Self.bundleID)"
                if (count of windows) = 0 then return ""
                set w to front window
                set t to active tab of w
                set r to execute t javascript \(appleScriptString(js))
                if r is missing value then return ""
                if r is "" or r is "none" then return r
                return ((id of w) as text) & "|" & ((id of t) as text) & "|" & r
            end tell
            """
        let out = try AppleScript.run(script)
        if out == "none" { return .noReachableVideo }
        let parts = out.split(separator: "|").map(String.init)
        guard parts.count == 3, let w = Int(parts[0]), let t = Int(parts[1]), let prev = Double(parts[2]) else {
            return .notNeeded
        }
        return .ducked(DuckToken(window: w, tab: t, previous: prev, level: level))
    }

    /// Puts the volume back on the tab that was ducked, unless the user changed it meanwhile.
    public func restore(_ token: DuckToken) throws {
        let js = """
            (() => { const vs = Array.from(document.querySelectorAll('video'));
              for (const v of vs) {
                if (v.dataset.ljVolume === undefined) continue;
                if (Math.abs(v.volume - \(token.level)) < 0.005) v.volume = Number(v.dataset.ljVolume);
                delete v.dataset.ljVolume;
              }
              return '';
            })()
            """
        // Chrome's ids exceed AppleScript's integer range (2^29), so `tab id N` does not
        // compile; match them as text instead.
        let script = """
            tell application id "\(Self.bundleID)"
                repeat with w in windows
                    if ((id of w) as text) is "\(token.window)" then
                        repeat with t in tabs of w
                            if ((id of t) as text) is "\(token.tab)" then
                                execute t javascript \(appleScriptString(js))
                                return ""
                            end if
                        end repeat
                    end if
                end repeat
                return ""
            end tell
            """
        _ = try AppleScript.run(script)
    }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

enum AppleScript {
    static func run(_ source: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw DriverError.appleScript(e.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return o.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum DriverError: Error, CustomStringConvertible {
    case appleScript(String)

    public var description: String {
        switch self {
        case .appleScript(let m):
            if m.contains("turned off") {
                return "Chrome blocks JavaScript from AppleScript. Turn on View > Developer > Allow JavaScript from Apple Events."
            }
            return "AppleScript failed: \(m)"
        }
    }
}
