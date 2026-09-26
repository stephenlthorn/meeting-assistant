import AVFoundation
import XCTest

@MainActor
final class MicCaptureTests: XCTestCase {
    func testStartingTwiceInstallsOneTap() throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)

        try mic.start()
        try mic.start()

        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertEqual(engine.starts, 1)
        XCTAssertEqual(engine.overlappingTapInstalls, 0)
    }

    func testTheMicrophoneCanBeStoppedAndStartedAgain() throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)

        try mic.start()
        mic.stop()
        try mic.start()

        XCTAssertEqual(engine.tapInstalls, 2)
        XCTAssertEqual(engine.overlappingTapInstalls, 0)
        XCTAssertTrue(engine.hasTap)
    }

    func testStoppingANeverStartedMicrophoneIsHarmless() {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)

        mic.stop()

        XCTAssertEqual(engine.tapRemovals, 0)
    }

    func testNoInputDeviceFailsToStart() {
        let engine = FakeAudioInputEngine()
        engine.inputFormat = nil
        let mic = MicCapture(engine: engine)

        XCTAssertThrowsError(try mic.start()) { error in
            XCTAssertEqual(error.localizedDescription, "No microphone input available.")
        }
        XCTAssertFalse(engine.hasTap)
    }

    func testAnEngineThatWontStartLeavesNoTapBehind() {
        let engine = FakeAudioInputEngine()
        engine.startError = TestFailure(message: "Device busy")
        let mic = MicCapture(engine: engine)

        XCTAssertThrowsError(try mic.start())
        XCTAssertFalse(engine.hasTap)
    }

    func testAudioArrivesAsMono() throws {
        let engine = FakeAudioInputEngine()
        engine.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        let mic = MicCapture(engine: engine)
        let received = Received()
        mic.onBuffer = { buffer in received.add(buffer) }

        try mic.start()
        engine.deliver(tone(amplitude: 0.2, sampleRate: 48_000, channels: 2))

        XCTAssertEqual(received.buffers.map(\.format.channelCount), [1])
    }

    func testAnInputDeviceChangeRestartsCaptureWithTheNewFormat() async throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)
        try mic.start()

        engine.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
        engine.simulateConfigurationChange()

        await eventually { engine.starts == 2 }
        XCTAssertEqual(engine.tapFormats.map(\.sampleRate), [48_000, 24_000])
        XCTAssertEqual(engine.overlappingTapInstalls, 0)
        XCTAssertTrue(engine.hasTap)
    }

    func testADeviceChangeWhileStoppedDoesNothing() async throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)
        try mic.start()
        mic.stop()

        engine.simulateConfigurationChange()
        await settle()

        XCTAssertEqual(engine.tapInstalls, 1)
        XCTAssertFalse(engine.hasTap)
    }

    func testAFailedRestartIsReported() async throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)
        var errors: [String] = []
        mic.onError = { errors.append($0) }
        try mic.start()

        engine.startError = TestFailure(message: "Device busy")
        engine.simulateConfigurationChange()

        await eventually { !errors.isEmpty }
        XCTAssertEqual(errors, ["Couldn't restart after the input device changed: Device busy"])
        XCTAssertFalse(engine.hasTap)
    }
}

final class FakeAudioInputEngine: AudioInputEngine {
    var inputFormat: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    var onConfigurationChange: (() -> Void)?
    var startError: Error?
    private(set) var tapFormats: [AVAudioFormat] = []
    private(set) var tapInstalls = 0
    private(set) var tapRemovals = 0
    private(set) var overlappingTapInstalls = 0
    private(set) var starts = 0
    private var tap: ((AVAudioPCMBuffer) -> Void)?

    var hasTap: Bool { tap != nil }

    func installTap(format: AVAudioFormat, block: @escaping (AVAudioPCMBuffer) -> Void) {
        if tap != nil { overlappingTapInstalls += 1 }
        tapInstalls += 1
        tapFormats.append(format)
        tap = block
    }

    func removeTap() {
        tapRemovals += 1
        tap = nil
    }

    func start() throws {
        if let startError { throw startError }
        starts += 1
    }

    func stop() {}

    func deliver(_ buffer: AVAudioPCMBuffer) { tap?(buffer) }

    func simulateConfigurationChange() {
        DispatchQueue.global().async { [onConfigurationChange] in onConfigurationChange?() }
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AVAudioPCMBuffer] = []

    var buffers: [AVAudioPCMBuffer] { lock.withLock { stored } }

    func add(_ buffer: AVAudioPCMBuffer) { lock.withLock { stored.append(buffer) } }
}
