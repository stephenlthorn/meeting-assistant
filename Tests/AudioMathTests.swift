import AVFoundation
import XCTest

final class AudioMathTests: XCTestCase {
    func testTheLevelOfAConstantToneIsItsAmplitude() {
        XCTAssertEqual(AudioMath.rms(tone(amplitude: 0.5)), 0.5, accuracy: 0.0001)
    }

    func testSilenceHasNoLevel() {
        XCTAssertEqual(AudioMath.rms(tone(amplitude: 0)), 0)
    }

    func testTheLevelAveragesEveryChannel() {
        let stereo = tone(amplitude: 0.5, channels: 2)
        for frame in 0..<Int(stereo.frameLength) { stereo.floatChannelData![1][frame] = 0 }

        XCTAssertEqual(AudioMath.rms(stereo), (0.125 as Float).squareRoot(), accuracy: 0.0001)
    }

    func testMixingStereoToMonoAveragesTheChannels() throws {
        let stereo = tone(amplitude: 0.2, channels: 2)
        for frame in 0..<Int(stereo.frameLength) { stereo.floatChannelData![1][frame] = 0.6 }

        let mono = try XCTUnwrap(AudioMath.monoMix(stereo))

        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, stereo.frameLength)
        XCTAssertEqual(mono.floatChannelData![0][0], 0.4, accuracy: 0.0001)
        XCTAssertEqual(mono.floatChannelData![0][Int(mono.frameLength) - 1], 0.4, accuracy: 0.0001)
    }

    func testMonoAudioIsPassedThroughUntouched() {
        let mono = tone(amplitude: 0.3)

        XCTAssertTrue(AudioMath.monoMix(mono) === mono)
    }
}
