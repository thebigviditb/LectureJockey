import Foundation

/// Reads a YouTube video's transcript from YouTube's own "Show transcript" panel,
/// without the viewer noticing.
///
/// Why the panel: the JavaScript Chrome runs from AppleScript lives in an isolated
/// world (no access to the page's variables), caption downloads return empty without
/// a token only YouTube's player makes, and the get_transcript request answers
/// FAILED_PRECONDITION when not sent by the panel itself. Reading what the panel
/// shows needs none of that.
///
/// How it stays invisible: before clicking, every panel the viewer has not opened is
/// moved off-screen (fixed, far left, transparent, no pointer events); after reading,
/// the panel is closed, the styling is removed only once it has collapsed (so it never
/// flashes in), and focus returns to whatever had it (usually the player, which owns
/// the keyboard shortcuts). Measured on two videos: player, side column, first
/// recommendation, scroll position and focus identical before and after.
///
/// If YouTube's layout changes, this fails with an error instead of saving a wrong
/// transcript; live transcription is the fallback.
public struct YouTubeTranscript: Sendable {
    public var timeout: TimeInterval = 8
    public var pollInterval: TimeInterval = 0.3

    public init() {}

    /// "https://www.youtube.com/watch?v=abc&t=1" -> "abc".
    public static func videoID(from url: String) -> String? {
        guard let c = URLComponents(string: url), let host = c.host, host.hasSuffix("youtube.com"),
              c.path == "/watch", let v = c.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty
        else { return nil }
        return v
    }

    public static func key(for videoID: String) -> String { "youtube:\(videoID)" }

    public func fetch(from tab: ChromeTabs.Tab) throws -> Transcript {
        guard let id = Self.videoID(from: tab.url) else { throw YouTubeTranscriptError.notAVideo }
        let opened = try ChromeTabs.run(Self.openJS, in: tab)
        // Whatever happens next, put the page back.
        defer { _ = try? closeAndRestore(tab) }
        guard opened.contains("\"clicked\":true") else {
            throw YouTubeTranscriptError.noTranscriptButton
        }

        let deadline = Date().addingTimeInterval(timeout)
        var result: ReadResult?
        var lastCount = -1
        while Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
            let raw = try ChromeTabs.run(Self.readJS, in: tab)
            let r = try JSONDecoder().decode(ReadResult.self, from: Data(raw.utf8))
            // Done once the line count holds steady across two reads, in case a long
            // transcript renders in batches.
            if r.ready, !r.segments.isEmpty, r.segments.count == lastCount { result = r; break }
            lastCount = r.ready ? r.segments.count : -1
        }
        guard let result else { throw YouTubeTranscriptError.timedOut }
        guard !result.panelOnScreen else { throw YouTubeTranscriptError.panelVisible }
        let lines = result.segments.compactMap { s in s.start.map { ($0, s.text) } }
        guard !lines.isEmpty, lines.count == result.segments.count else { throw YouTubeTranscriptError.unexpectedLayout }
        return Transcript.fromCaptions(key: Self.key(for: id), title: result.title, duration: result.duration, starts: lines)
    }

    private func closeAndRestore(_ tab: ChromeTabs.Tab) throws {
        // The first close starts the collapse; styling is restored once it is done.
        for _ in 0..<10 {
            let out = try ChromeTabs.run(Self.closeJS, in: tab)
            if out.contains("\"restored\":true") { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    struct ReadResult: Decodable {
        struct Segment: Decodable { let start: Double?; let text: String }
        let ready: Bool
        let segments: [Segment]
        let title: String
        let duration: Double
        let panelOnScreen: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ready = try c.decode(Bool.self, forKey: .ready)
            segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            panelOnScreen = try c.decodeIfPresent(Bool.self, forKey: .panelOnScreen) ?? false
        }

        enum CodingKeys: String, CodingKey { case ready, segments, title, duration, panelOnScreen }
    }

    // MARK: - Page scripts (raw strings: regex backslashes stay as written)

    static let openJS = #"""
    (() => {
      const EXPANDED = 'ENGAGEMENT_PANEL_VISIBILITY_EXPANDED';
      for (const p of document.querySelectorAll('ytd-engagement-panel-section-list-renderer')) {
        if (p.getAttribute('visibility') === EXPANDED) continue;
        p.dataset.ljOffscreen = '1';
        for (const [k, v] of [['position', 'fixed'], ['left', '-10000px'], ['top', '0'], ['width', '400px'],
                              ['height', '900px'], ['opacity', '0'], ['pointer-events', 'none']]) {
          p.style.setProperty(k, v, 'important');
        }
      }
      const focused = document.activeElement;
      if (focused && focused !== document.body) focused.setAttribute('data-lj-focus', '1');
      const btn = document.querySelector('ytd-video-description-transcript-section-renderer button');
      if (!btn) return JSON.stringify({clicked: false});
      btn.click();
      if (focused && focused !== document.activeElement && focused.focus) focused.focus({preventScroll: true});
      return JSON.stringify({clicked: true});
    })()
    """#

    static let readJS = #"""
    (() => {
      const EXPANDED = 'ENGAGEMENT_PANEL_VISIBILITY_EXPANDED';
      const panel = Array.from(document.querySelectorAll('ytd-engagement-panel-section-list-renderer[data-lj-offscreen]'))
        .find(p => p.getAttribute('visibility') === EXPANDED && p.querySelector('transcript-segment-view-model'));
      if (!panel) return JSON.stringify({ready: false});
      const toSec = (ts) => ts.split(':').reduce((a, x) => a * 60 + Number(x), 0);
      const segments = Array.from(panel.querySelectorAll('transcript-segment-view-model')).map(r => {
        const lines = (r.innerText || r.textContent || '').split('\n').map(s => s.trim()).filter(Boolean);
        const ts = lines.find(l => /^\d{1,2}(:\d{2}){1,2}$/.test(l)) || '';
        const text = lines.filter(l => l !== ts && !/^\d+ (hours?|minutes?|seconds?)(, \d+ (minutes?|seconds?))*$/.test(l)).join(' ');
        return {start: ts ? toSec(ts) : null, text};
      });
      const rect = panel.getBoundingClientRect();
      const v = document.querySelector('video');
      const title = (document.querySelector('ytd-watch-metadata h1') || {}).textContent || document.title.replace(/ - YouTube$/, '');
      return JSON.stringify({ready: true, segments, title: title.trim(),
        duration: v && isFinite(v.duration) ? v.duration : 0,
        panelOnScreen: rect.right > 0 && rect.left < window.innerWidth && rect.bottom > 0 && rect.top < window.innerHeight});
    })()
    """#

    static let closeJS = #"""
    (() => {
      const EXPANDED = 'ENGAGEMENT_PANEL_VISIBILITY_EXPANDED';
      const ours = Array.from(document.querySelectorAll('ytd-engagement-panel-section-list-renderer[data-lj-offscreen]'));
      for (const p of ours.filter(p => p.getAttribute('visibility') === EXPANDED)) {
        const b = p.querySelector('#visibility-button button, button[aria-label*="Close" i]');
        if (b) b.click();
      }
      const stillOpen = ours.filter(p => p.getAttribute('visibility') === EXPANDED).length;
      if (stillOpen === 0) {
        for (const p of ours) {
          for (const k of ['position', 'left', 'top', 'width', 'height', 'opacity', 'pointer-events']) p.style.removeProperty(k);
          delete p.dataset.ljOffscreen;
        }
        const f = document.querySelector('[data-lj-focus]');
        if (f) { f.removeAttribute('data-lj-focus'); if (document.activeElement !== f) f.focus({preventScroll: true}); }
      }
      return JSON.stringify({stillOpen, restored: stillOpen === 0});
    })()
    """#
}

public enum YouTubeTranscriptError: Error, CustomStringConvertible, Equatable {
    case notAVideo, noTranscriptButton, timedOut, panelVisible, unexpectedLayout

    public var description: String {
        switch self {
        case .notAVideo: return "not a YouTube video page"
        case .noTranscriptButton: return "no Show transcript button (the video may have no transcript, or YouTube's layout changed)"
        case .timedOut: return "the transcript panel did not load in time"
        case .panelVisible: return "the transcript panel was on screen; stopped so it is not shown"
        case .unexpectedLayout: return "transcript lines without timestamps (YouTube's layout may have changed)"
        }
    }
}
