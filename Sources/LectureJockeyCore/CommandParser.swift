import Foundation

/// Turns a whole dictated utterance into a `Command`, or nil when the utterance
/// is not exactly a command. The match is on the entire utterance, never a
/// phrase inside a longer sentence, so ordinary dictation does not trigger it.
public enum CommandParser {
    /// Step used by "speed up" / "slow down" without a target rate.
    public static let rateStep = 0.25

    public static func parse(_ text: String) -> Command? {
        let words = normalize(text)
        guard !words.isEmpty, words.count <= 12 else { return nil }
        let s = words.joined(separator: " ")

        if let c = parsePlayPause(s) { return c }
        if let c = parseRate(s) { return c }
        if let c = parseSeek(s) { return c }
        if let c = parseSeekTo(s) { return c }
        return nil
    }

    // MARK: - Play / pause

    private static func parsePlayPause(_ s: String) -> Command? {
        let target = "(?: (?:the )?(?:video|lecture))?"
        if s.wholeMatch("(?:pause|stop)\(target)") { return .pause }
        if s.wholeMatch("(?:play|resume|unpause)\(target)") { return .play }
        return nil
    }

    // MARK: - Rate

    private static func parseRate(_ s: String) -> Command? {
        if s.wholeMatch("(?:(?:go )?back to )?(?:normal|regular) speed") { return .setRate(1) }

        // "2x", "speed 2x", "speed up to 2x", "set the speed to 1.5x",
        // "play at 2x", "2 times speed", "playback speed 2".
        let prefix = "(?:(?:set )?(?:the )?(?:playback )?speed(?: it)?(?: up| down)?(?: to)? |(?:play|go) at |speed (?:up|down) (?:to )?)?"
        let rate = "(\\d+(?:\\.\\d+)?)"
        let suffix = "(?:x| x| times(?: speed)?| speed)"
        if let m = s.wholeCaptures("\(prefix)\(rate)\(suffix)"), let r = Double(m[0]) {
            return validRate(r)
        }
        // Bare number after an explicit speed phrase: "set the speed to 2".
        if let m = s.wholeCaptures("(?:set )?(?:the )?(?:playback )?speed (?:up |down )?to \(rate)"), let r = Double(m[0]) {
            return validRate(r)
        }

        if s.wholeMatch("(?:speed (?:it |this |the video )?up|faster|go faster)") { return .changeRate(by: rateStep) }
        if s.wholeMatch("(?:slow (?:it |this |the video )?down|slower|go slower)") { return .changeRate(by: -rateStep) }
        return nil
    }

    private static func validRate(_ r: Double) -> Command? {
        (0.25...4).contains(r) ? .setRate(r) : nil
    }

    // MARK: - Seek

    private static func parseSeek(_ s: String) -> Command? {
        let back = "(?:(?:go |skip |jump )?back(?:wards?)?|rewind)"
        let fwd = "(?:(?:go |skip |jump |fast )?(?:forwards?|ahead)|skip|fast forward)"
        let amount = "(?: by)? (\\d+(?:\\.\\d+)?) (seconds?|secs?|s|minutes?|mins?|m)"

        if let m = s.wholeCaptures("\(back)\(amount)"), let secs = seconds(m[0], m[1]) {
            return .seek(by: -secs)
        }
        if let m = s.wholeCaptures("\(fwd)\(amount)"), let secs = seconds(m[0], m[1]) {
            return .seek(by: secs)
        }
        return nil
    }

    // MARK: - Seek to a position

    private static func parseSeekTo(_ s: String) -> Command? {
        let media = "(?: (?:of )?(?:the |this )?(?:video|lecture))?"
        let start = "(?:beginning|start)"
        if s.wholeMatch("(?:(?:go|jump|skip|rewind) )?(?:back |all the way back )?to (?:the )?\(start)\(media)") { return .seekTo(0) }
        if s.wholeMatch("(?:restart|start over|start from the \(start))\(media)") { return .seekTo(0) }

        // Positions relative to the length: "the middle", "halfway", "the end",
        // "75 percent of the way", "a third of the way through", "three quarters".
        let to = "(?:(?:go|jump|skip|seek)(?: back| ahead| forward)? to |(?:go|jump|skip) )"
        let through = "(?: (?:of )?the way)?(?: (?:through|in|into))?\(media)"
        if s.wholeMatch("\(to)(?:the )?(?:middle|half ?way(?: point)?)\(through)") { return .seekToFraction(0.5) }
        if s.wholeMatch("\(to)(?:the )?end\(media)") { return .seekToFraction(1) }
        if let m = s.wholeCaptures("\(to)(\\d+(?:\\.\\d+)?) ?(?:percent|%)\(through)"), let p = Double(m[0]), p <= 100 {
            return .seekToFraction(p / 100)
        }
        let fractions: [(String, Double)] = [
            ("(?:a|1) quarter", 0.25), ("(?:a|1) third", 1.0 / 3), ("2 thirds", 2.0 / 3), ("3 quarters", 0.75),
        ]
        for (words, f) in fractions where s.wholeMatch("\(to)\(words)\(through)") {
            return .seekToFraction(f)
        }

        let go = "(?:go|jump|skip|seek)(?: back| ahead| forward)? to"
        let mins = "(?:minutes?|mins?|m)"
        let secs = "(?:seconds?|secs?|s)"
        // "go to 5 minutes", "jump to 1 minute 30 seconds", "skip to 2 minutes and 15 seconds"
        if let m = s.wholeCaptures("\(go) (\\d+) \(mins)(?: (?:and )?(\\d+) \(secs))?"),
           let mm = Double(m[0]) {
            return position(mm * 60 + (m.count > 1 ? Double(m[1]) ?? 0 : 0))
        }
        // "go to minute 12"
        if let m = s.wholeCaptures("\(go) minute (\\d+)"), let mm = Double(m[0]) { return position(mm * 60) }
        // "go to 90 seconds"
        if let m = s.wholeCaptures("\(go) (\\d+) \(secs)"), let ss = Double(m[0]) { return position(ss) }
        // "jump to 2:30" (normalized to "2 30"), "go to 1:02:30"
        if let m = s.wholeCaptures("\(go) (\\d+) (\\d{2})(?: (\\d{2}))?"), let a = Double(m[0]), let b = Double(m[1]) {
            if m.count > 2, let c = Double(m[2]) { return position(a * 3600 + b * 60 + c) }
            return b < 60 ? position(a * 60 + b) : nil
        }
        return nil
    }

    private static func position(_ secs: Double) -> Command? {
        secs <= 24 * 3600 ? .seekTo(secs) : nil
    }

    private static func seconds(_ n: String, _ unit: String) -> Double? {
        guard let v = Double(n), v > 0 else { return nil }
        let secs = unit.hasPrefix("m") ? v * 60 : v
        return secs <= 6 * 3600 ? secs : nil
    }

    // MARK: - Normalization

    /// Lowercases, strips punctuation (keeping decimal points), drops filler
    /// words and turns number words ("thirty five", "a minute", "one and a
    /// half") into digits.
    static func normalize(_ text: String) -> [String] {
        var t = text.lowercased()
        t = t.replacingOccurrences(of: "×", with: "x")
        t = t.replacingOccurrences(of: "%", with: " percent")
        t = t.replacingOccurrences(of: "(?<!\\d)\\.|\\.(?!\\d)", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[^a-z0-9. ]", with: " ", options: .regularExpression)
        var words = t.split(separator: " ").map(String.init)
        words = joinNumberWords(words)
        words = words.filter { !fillers.contains($0) }
        return words
    }

    private static let fillers: Set<String> = ["please", "uh", "um", "okay", "ok", "hey", "can", "you", "now"]

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// "thirty five" -> "35", "a minute" -> "1 minute", "one and a half" -> "1.5",
    /// "half a minute" -> "30 seconds", "two x" stays "2 x".
    private static func joinNumberWords(_ words: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil

            if w == "half", next == "a" || next == "an", i + 2 < words.count, words[i + 2].hasPrefix("min") {
                out += ["30", "seconds"]; i += 3; continue
            }
            if (w == "a" || w == "an"), let n = next, n.hasPrefix("min") || n.hasPrefix("sec") {
                out.append("1"); i += 1; continue
            }

            var value: Double?
            var consumed = 0
            if let t = tens[w] {
                value = Double(t); consumed = 1
                if let n = next, let u = units[n], u < 10 { value! += Double(u); consumed = 2 }
            } else if let u = units[w] {
                value = Double(u); consumed = 1
            }
            if var v = value {
                // "one and a half"
                let rest = Array(words.dropFirst(i + consumed).prefix(3))
                if rest == ["and", "a", "half"] { v += 0.5; consumed += 3 }
                out.append(Command.format(v))
                i += consumed
                continue
            }
            out.append(w)
            i += 1
        }
        return out
    }
}

private extension String {
    func wholeMatch(_ pattern: String) -> Bool {
        range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }

    func wholeCaptures(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^(?:\(pattern))$"),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) }
        }
    }
}
