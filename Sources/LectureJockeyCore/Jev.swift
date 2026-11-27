import Foundation
import Security

/// Classifies a dictation that no grammar rule matched, using TypeSafe's Jev
/// decision model: it scores a fixed list of choices and returns a probability
/// for each. Jev picks the action (and, for relative jumps, the position); the
/// numbers ("30 seconds", "2x", "75%") come from `Slots`, never from the model.
///
/// Adding a feature means adding a choice here, not retraining anything.
public struct JevClassifier: Sendable {
    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    public static let model = "jev-latest"
    /// Measured on the phrase list in Tests: every answer at or above this was right.
    public static let defaultThreshold = 0.9

    public enum Intent: String, CaseIterable, Sendable {
        case seekBack = "seek_back", seekForward = "seek_forward", seekToTime = "seek_to_time"
        case seekToPosition = "seek_to_position", faster, slower, setRate = "set_rate"
        case normalSpeed = "normal_speed", pause, play, notACommand = "not_a_command"

        var criterion: String {
            switch self {
            case .seekBack: return "rewind or go back by an amount of time"
            case .seekForward: return "skip ahead or forward by an amount of time"
            case .seekToTime: return "jump to a specific timestamp like 5 minutes or 2:30"
            case .seekToPosition: return "jump to a position relative to the length: beginning, middle, end, a percentage, a fraction"
            case .faster: return "increase playback speed without a specific value"
            case .slower: return "decrease playback speed without a specific value"
            case .setRate: return "set a specific playback speed like 2x or 1.5x"
            case .normalSpeed: return "return to normal 1x speed"
            case .pause: return "pause or stop playback"
            case .play: return "play or resume playback"
            case .notACommand: return "anything else: conversation, notes, dictation, remarks or opinions about the video, sentences that only mention speed or time"
            }
        }
    }

    public enum Position: String, CaseIterable, Sendable {
        case beginning, quarter, third, middle, twoThirds = "two_thirds", threeQuarters = "three_quarters"
        case end, percentage, none

        var criterion: String {
            switch self {
            case .beginning: return "the start of the video"
            case .quarter: return "a quarter of the way"
            case .third: return "a third of the way"
            case .middle: return "the middle or halfway"
            case .twoThirds: return "two thirds of the way"
            case .threeQuarters: return "three quarters of the way"
            case .end: return "the end"
            case .percentage: return "a percentage given as a number"
            case .none: return "no position is mentioned"
            }
        }

        var fraction: Double? {
            switch self {
            case .beginning: return 0
            case .quarter: return 0.25
            case .third: return 1.0 / 3
            case .middle: return 0.5
            case .twoThirds: return 2.0 / 3
            case .threeQuarters: return 0.75
            case .end: return 1
            case .percentage, .none: return nil
            }
        }
    }

    public struct Answer: Sendable, Equatable {
        public let intent: Intent
        public let confidence: Double
        public let position: Position
    }

    public let apiKey: String
    public let threshold: Double
    public let timeout: TimeInterval

    public init(apiKey: String, threshold: Double = JevClassifier.defaultThreshold, timeout: TimeInterval = 4) {
        self.apiKey = apiKey
        self.threshold = threshold
        self.timeout = timeout
    }

    /// Reads the key saved with `security add-generic-password -s LectureJockey -a typesafe -w`.
    public static func fromKeychain() -> JevClassifier? {
        Keychain.read(service: "LectureJockey", account: "typesafe").map { JevClassifier(apiKey: $0) }
    }

    // MARK: - Request

    static func requestBody(for text: String) -> [String: Any] {
        [
            "model": model,
            "state": "Spoken to a video player while watching a lecture: \"\(text)\"",
            "questions": [
                "intent": [
                    "type": "choice",
                    "instructions": "Which playback action does the speaker want? If the sentence is not a request to control the video, choose not_a_command.",
                    "criteria": Dictionary(uniqueKeysWithValues: Intent.allCases.map { ($0.rawValue, $0.criterion) }),
                ],
                "position": [
                    "type": "choice",
                    "instructions": "If the speaker wants to jump to a position relative to the video's length, which one?",
                    "criteria": Dictionary(uniqueKeysWithValues: Position.allCases.map { ($0.rawValue, $0.criterion) }),
                ],
            ],
        ]
    }

    public func classify(_ text: String) throws -> Answer {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(for: text))

        let (data, status) = try Self.send(request)
        guard status == 200 else {
            throw JevError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> Answer {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = obj["answers"] as? [String: Any],
              let intent = answers["intent"] as? [String: Any],
              let choice = (intent["choice"] as? String).flatMap(Intent.init(rawValue:)),
              let confidence = intent["confidence"] as? Double
        else { throw JevError.badResponse }
        let position = ((answers["position"] as? [String: Any])?["choice"] as? String).flatMap(Position.init(rawValue:)) ?? .none
        return Answer(intent: choice, confidence: confidence, position: position)
    }

    private static func send(_ request: URLRequest) throws -> (Data, Int) {
        final class Box: @unchecked Sendable { var result: Result<(Data, Int), Error> = .failure(JevError.badResponse) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else {
                box.result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }

    // MARK: - Answer to command

    /// The command for a confident answer, with numbers taken from the text.
    /// Nil when Jev is unsure, says it is not a command, or a needed number is missing.
    public func command(for answer: Answer, text: String) -> Command? {
        guard answer.confidence >= threshold else { return nil }
        let words = CommandParser.normalize(text)
        switch answer.intent {
        case .notACommand: return nil
        case .pause: return .pause
        case .play: return .play
        case .normalSpeed: return .setRate(1)
        case .faster: return .changeRate(by: CommandParser.rateStep)
        case .slower: return .changeRate(by: -CommandParser.rateStep)
        case .setRate: return Slots.rate(words).map(Command.setRate)
        case .seekBack: return .seek(by: -(Slots.duration(words) ?? Slots.defaultSeek))
        case .seekForward: return .seek(by: Slots.duration(words) ?? Slots.defaultSeek)
        case .seekToTime: return Slots.timestamp(words).map(Command.seekTo)
        case .seekToPosition:
            if let p = Slots.percent(words) { return .seekToFraction(p / 100) }
            return answer.position.fraction.map(Command.seekToFraction)
        }
    }
}

public enum JevError: Error, CustomStringConvertible {
    case http(Int, String)
    case badResponse

    public var description: String {
        switch self {
        case .http(let code, let body): return "Jev HTTP \(code): \(body)"
        case .badResponse: return "Jev returned an unexpected response"
        }
    }
}

/// Numbers pulled out of a normalized utterance, so the model never has to produce them.
public enum Slots {
    /// "go back a bit" with no amount.
    public static let defaultSeek: Double = 10

    /// "30 seconds", "2 minutes", "1 minute 30 seconds" (number words already digits).
    public static func duration(_ words: [String]) -> Double? {
        let s = words.joined(separator: " ")
        let pattern = "(\\d+(?:\\.\\d+)?) (minutes?|mins?|m|seconds?|secs?|s)\\b(?: (?:and )?(\\d+(?:\\.\\d+)?) (seconds?|secs?|s)\\b)?"
        guard let m = captures(s, pattern), let n = Double(m[0]) else { return nil }
        var secs = m[1].hasPrefix("m") ? n * 60 : n
        if m.count > 3, let extra = Double(m[2]) { secs += extra }
        return secs > 0 ? secs : nil
    }

    /// "2:30" (normalized "2 30"), "1:02:30", or a duration from the start ("two minutes in").
    public static func timestamp(_ words: [String]) -> Double? {
        let s = words.joined(separator: " ")
        if let m = captures(s, "\\b(\\d+) (\\d{2}) (\\d{2})\\b"), let h = Double(m[0]), let mm = Double(m[1]), let ss = Double(m[2]) {
            return h * 3600 + mm * 60 + ss
        }
        if let m = captures(s, "\\b(\\d+) (\\d{2})\\b"), let mm = Double(m[0]), let ss = Double(m[1]), ss < 60 {
            return mm * 60 + ss
        }
        if let m = captures(s, "\\bminute (\\d+)\\b"), let mm = Double(m[0]) { return mm * 60 }
        return duration(words)
    }

    /// "2x", "1.5 times", "double", "half speed", or a bare number in the valid range.
    public static func rate(_ words: [String]) -> Double? {
        let s = words.joined(separator: " ")
        var r: Double?
        if let m = captures(s, "(\\d+(?:\\.\\d+)?) ?(?:x|times)\\b") { r = Double(m[0]) }
        else if s.contains("double") { r = 2 }
        else if s.contains("triple") { r = 3 }
        else if s.contains("half speed") { r = 0.5 }
        else if let m = captures(s, "\\b(\\d+(?:\\.\\d+)?)\\b") { r = Double(m[0]) }
        guard let r, (0.25...4).contains(r) else { return nil }
        return r
    }

    /// "75 percent" (normalized from "75%").
    public static func percent(_ words: [String]) -> Double? {
        let s = words.joined(separator: " ")
        guard let m = captures(s, "(\\d+(?:\\.\\d+)?) percent"), let p = Double(m[0]), (0...100).contains(p) else { return nil }
        return p
    }

    private static func captures(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
