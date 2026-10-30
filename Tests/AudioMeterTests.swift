import AVFoundation
import XCTest

final class AudioMeterTests: XCTestCase {
    func testTheFirstBufferIsReportedAtOnce() {
        let h = MeterHarness()

        h.meter.observe(h.buffer(amplitude: 0.5))

        XCTAssertEqual(h.levels.count, 1)
        XCTAssertEqual(h.levels[0], 0.5, accuracy: 0.0001)
    }

    func testLevelsAreReportedAtMostTenTimesASecondWhateverTheBufferSize() {
        let h = MeterHarness()

        for _ in 0..<300 {
            h.meter.observe(h.buffer(amplitude: 0.2))
            h.clock.advance(0.01)
        }

        XCTAssertEqual(h.levels.count, 30, accuracy: 1, "300 buffers over 3 s")
    }

    func testTheReportedLevelIsTheLoudnessOverTheWholeInterval() {
        let h = MeterHarness()
        h.meter.observe(h.buffer(amplitude: 0))

        h.clock.advance(0.02)
        h.meter.observe(h.buffer(amplitude: 0.6))
        h.meter.observe(h.buffer(amplitude: 0.8))
        h.clock.advance(0.1)
        h.meter.observe(h.buffer(amplitude: 0))

        XCTAssertEqual(h.levels.count, 2)
        XCTAssertEqual(h.levels[1], (1 / 3 as Float).squareRoot(), accuracy: 0.0001,
                       "the loud buffers and the quiet one around them, not just the last one")
    }

    func testBuffersAreCountedEvenWhenTheyAreSilent() {
        let h = MeterHarness()

        for _ in 0..<5 { h.meter.observe(h.buffer(amplitude: 0)) }

        XCTAssertEqual(h.meter.reading().buffers, 5)
        XCTAssertEqual(h.meter.reading().voicedSeconds, 0)
    }

    func testOnlyAudioAboveTheVoiceLevelCountsAsVoiced() {
        let h = MeterHarness()

        for _ in 0..<100 { h.meter.observe(h.buffer(amplitude: 0.001)) }
        XCTAssertEqual(h.meter.reading().voicedSeconds, 0, "a hiss is not a voice")

        for _ in 0..<100 { h.meter.observe(h.buffer(amplitude: 0.05)) }
        XCTAssertEqual(h.meter.reading().voicedSeconds, 1, accuracy: 0.0001, "100 buffers of 10 ms")
    }

    func testReadingsAreSafeToTakeWhileBuffersArriveOnAnotherThread() {
        let h = MeterHarness()
        let done = expectation(description: "capture thread finished")
        DispatchQueue.global().async {
            for _ in 0..<2_000 { h.meter.observe(h.buffer(amplitude: 0.1)) }
            done.fulfill()
        }

        var last = 0
        while h.meter.reading().buffers < 2_000 {
            let now = h.meter.reading().buffers
            XCTAssertGreaterThanOrEqual(now, last)
            last = now
        }

        wait(for: [done], timeout: 10)
    }
}

/// A meter over a clock the test moves, collecting what it publishes.
private final class MeterHarness: @unchecked Sendable {
    let clock = MeterClock()
    let meter: AudioMeter
    private let sink = LevelSink()

    var levels: [Float] { sink.levels }

    init() {
        let clock = self.clock
        let sink = self.sink
        meter = AudioMeter(clock: { clock.seconds }, onLevel: { sink.add($0) })
    }

    /// 10 ms of constant audio.
    func buffer(amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for frame in 0..<160 { buffer.floatChannelData![0][frame] = amplitude }
        return buffer
    }
}

private final class LevelSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Float] = []

    var levels: [Float] { lock.withLock { stored } }

    func add(_ level: Float) { lock.withLock { stored.append(level) } }
}
