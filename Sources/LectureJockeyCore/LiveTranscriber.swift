@preconcurrency import AVFoundation
import Foundation
import Speech

/// Transcribes an app's audio as it plays, on this Mac, with Apple's speech
/// recognizer (SpeechAnalyzer, macOS 26). Reports each finished sentence with the
/// wall-clock times it was heard; `PlaybackClock` turns those into video time.
public final class LiveTranscriber: @unchecked Sendable {
    public struct Heard: Sendable {
        public let start: Date
        public let end: Date
        public let text: String
    }

    public let bundlePrefix: String
    public let locale: Locale
    private let listener: AudioListener
    private let queue = DispatchQueue(label: "lecturejockey.live")
    private var timer: DispatchSourceTimer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var framesFed: Int64 = 0
    private var onHeard: (@Sendable (Heard) -> Void)?
    private var onError: (@Sendable (String) -> Void)?

    public init(bundlePrefix: String = ChromeDriver.bundleID, locale: Locale = Locale(identifier: "en-US")) {
        self.bundlePrefix = bundlePrefix
        self.locale = locale
        listener = AudioListener(bundlePrefix: bundlePrefix)
    }

    public var isRunning: Bool { queue.sync { analyzer != nil } }

    /// Starts listening and transcribing. Installs the speech model on first use.
    public func start(onHeard: @escaping @Sendable (Heard) -> Void, onError: @escaping @Sendable (String) -> Void) async throws {
        guard !isRunning else { return }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveError.noAudioFormat
        }
        try listener.start()
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: listener.sampleRate,
                                   channels: AVAudioChannelCount(listener.channels), interleaved: true)!
        guard let converter = AVAudioConverter(from: source, to: target) else {
            listener.stop()
            throw LiveError.noConverter
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)

        let listener = self.listener
        let results = Task {
            do {
                for try await r in transcriber.results where r.isFinal {
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let origin = listener.startDate else { continue }
                    onHeard(Heard(start: origin.addingTimeInterval(r.range.start.seconds),
                                  end: origin.addingTimeInterval(r.range.end.seconds), text: text))
                }
            } catch {
                onError("speech recognition stopped: \(error)")
            }
        }

        queue.sync {
            self.converter = converter
            self.inputFormat = source
            self.outputFormat = target
            self.continuation = continuation
            self.analyzer = analyzer
            self.resultsTask = results
            self.onHeard = onHeard
            self.onError = onError
            self.framesFed = 0
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { [weak self] in self?.feed() }
            timer.resume()
            self.timer = timer
        }
    }

    /// Stops listening and finishes the last sentence.
    public func stop() async {
        let (finishing, results) = queue.sync { () -> (SpeechAnalyzer?, Task<Void, Never>?) in
            timer?.cancel()
            timer = nil
            feed()
            continuation?.finish()
            continuation = nil
            listener.stop()
            let a = analyzer, r = resultsTask
            analyzer = nil
            resultsTask = nil
            return (a, r)
        }
        try? await finishing?.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
    }

    /// On `queue`: converts what the tap captured and hands it to the analyzer.
    private func feed() {
        guard let converter, let inputFormat, let outputFormat, let continuation else { return }
        let samples = listener.drain()
        let channels = Int(inputFormat.channelCount)
        let frames = samples.count / channels
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        input.frameLength = AVAudioFrameCount(frames)
        samples.withUnsafeBufferPointer { src in
            input.mutableAudioBufferList.pointee.mBuffers.mData?.copyMemory(from: src.baseAddress!, byteCount: frames * channels * 4)
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64) else { return }
        final class Once: @unchecked Sendable { var given = false }
        let once = Once()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if once.given { status.pointee = .noDataNow; return nil }
            once.given = true
            status.pointee = .haveData
            return input
        }
        if let error { onError?("audio conversion failed: \(error)"); return }
        guard output.frameLength > 0 else { return }
        // Stream time counts from the first sample, so result ranges map to wall time
        // through the listener's start date.
        let start = CMTime(value: framesFed, timescale: CMTimeScale(outputFormat.sampleRate))
        framesFed += Int64(output.frameLength)
        continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: start))
    }
}

public enum LiveError: Error, CustomStringConvertible {
    case noAudioFormat, noConverter
    public var description: String {
        switch self {
        case .noAudioFormat: return "the speech recognizer has no usable audio format"
        case .noConverter: return "cannot convert the app's audio for the speech recognizer"
        }
    }
}
