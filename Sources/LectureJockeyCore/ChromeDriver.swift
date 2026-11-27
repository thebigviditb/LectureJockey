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
