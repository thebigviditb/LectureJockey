import CoreAudio
import Foundation
import Testing
@testable import LectureJockeyCore

struct ChromeAudioTapTests {
    /// Runs `copy` on one interleaved input buffer and one output buffer.
    func run(input: [Float], inChannels: UInt32, outFrames: Int, outChannels: UInt32, gain: Float) -> [Float] {
        var inSamples = input
        var outSamples = [Float](repeating: 99, count: outFrames * Int(outChannels))
        return inSamples.withUnsafeMutableBytes { inRaw in
            outSamples.withUnsafeMutableBytes { outRaw in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: inChannels, mDataByteSize: UInt32(inRaw.count), mData: inRaw.baseAddress))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: outChannels, mDataByteSize: UInt32(outRaw.count), mData: outRaw.baseAddress))
                ChromeAudioTap.copy(&inList, to: &outList, gain: gain)
                return Array(outRaw.bindMemory(to: Float.self))
            }
        }
    }

    @Test func scalesStereoToStereo() {
        let out = run(input: [1, -1, 0.5, -0.5], inChannels: 2, outFrames: 2, outChannels: 2, gain: 0.1)
        #expect(out.map { ($0 * 1000).rounded() / 1000 } == [0.1, -0.1, 0.05, -0.05])
    }

    @Test func stereoToMonoTakesTheFirstChannel() {
        let out = run(input: [1, -1, 0.5, -0.5], inChannels: 2, outFrames: 2, outChannels: 1, gain: 1)
        #expect(out == [1, 0.5])
    }

    @Test func stereoToFourChannelsRepeatsTheLastChannel() {
        let out = run(input: [1, -1], inChannels: 2, outFrames: 1, outChannels: 4, gain: 1)
        #expect(out == [1, -1, -1, -1])
    }

    @Test func fillsSilenceWhenTheTapHasFewerFrames() {
        let out = run(input: [1, 1], inChannels: 2, outFrames: 3, outChannels: 2, gain: 1)
        #expect(out == [1, 1, 0, 0, 0, 0])
    }
}
