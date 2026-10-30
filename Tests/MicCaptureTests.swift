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

    func testTheTapIsInstalledWithoutAFormatSoADeviceChangeCannotRaiseAFormatMismatch() throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)

        try mic.start()

        XCTAssertEqual(engine.requestedTapFormats.count, 1)
        XCTAssertNil(engine.requestedTapFormats[0] ?? nil)
    }

    func testAFailedRestartStaysArmedAndRetriesOnTheNextDeviceChange() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()

        engine.inputFormat = nil
        engine.simulateConfigurationChange()
        await eventually { engine.tapRemovals >= 1 && !engine.hasTap && !h.scheduler.delays.isEmpty }

        engine.inputFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
        engine.simulateConfigurationChange()

        await eventually { engine.starts == 2 && engine.hasTap }
        XCTAssertEqual(engine.tapFormats.map(\.sampleRate), [48_000, 24_000])
        XCTAssertEqual(engine.overlappingTapInstalls, 0)
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testAFailedRestartIsRetriedWithBackoffUntilItWorks() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()

        engine.startError = TestFailure(message: "Device busy")
        engine.simulateConfigurationChange()
        await eventually { h.scheduler.delays == [1] }
        h.scheduler.fireAll()
        await eventually { h.scheduler.delays == [2] }
        engine.startError = nil
        h.scheduler.fireAll()

        await eventually { engine.starts == 2 && engine.hasTap }
        XCTAssertTrue(h.errors.isEmpty, "a quick recovery is not worth telling anyone")
        XCTAssertEqual(h.recoveries, 0)
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }

    func testAMicrophoneThatStaysDownIsReportedOnceAndRecoveryIsReported() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()
        engine.startError = TestFailure(message: "Device busy")
        engine.simulateConfigurationChange()

        for delay in MicCapture.retryDelays {
            await eventually { h.scheduler.delays == [delay] }
            XCTAssertTrue(h.errors.isEmpty)
            h.scheduler.fireAll()
        }

        await eventually { !h.errors.isEmpty }
        await settle()
        XCTAssertEqual(h.errors, ["Couldn't restart after the input device changed: Device busy"])
        XCTAssertTrue(h.scheduler.delays.isEmpty, "it stops polling but stays armed for the next device change")
        XCTAssertFalse(engine.hasTap)

        engine.startError = nil
        engine.simulateConfigurationChange()
        await eventually { engine.hasTap && h.recoveries == 1 }
        XCTAssertEqual(h.errors.count, 1)
    }

    func testAFreshDeviceChangeGetsAFreshRetryBudget() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()
        engine.startError = TestFailure(message: "Device busy")
        engine.simulateConfigurationChange()
        await eventually { h.scheduler.delays == [1] }
        h.scheduler.fireAll()
        await eventually { h.scheduler.delays == [2] }

        engine.simulateConfigurationChange()

        await eventually { h.scheduler.delays.contains(1) }
        h.scheduler.fireAll()
        await eventually { h.scheduler.delays == [2] }
    }

    // MARK: - Reconnecting on request (M1)

    func testReconnectingRebuildsTheTapLikeADeviceChange() throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)
        try mic.start()

        mic.reconnect()

        XCTAssertEqual(engine.tapInstalls, 2)
        XCTAssertEqual(engine.starts, 2)
        XCTAssertEqual(engine.overlappingTapInstalls, 0)
        XCTAssertTrue(engine.hasTap)
    }

    func testAReconnectThatFailsRetriesWithTheSameBackoff() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()
        engine.startError = TestFailure(message: "Device busy")

        h.mic.reconnect()

        XCTAssertEqual(h.scheduler.delays, [1])
        engine.startError = nil
        h.scheduler.fireAll()
        await eventually { engine.starts == 2 && engine.hasTap }
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testReconnectingAMicrophoneThatIsNotRunningDoesNothing() throws {
        let engine = FakeAudioInputEngine()
        let mic = MicCapture(engine: engine)

        mic.reconnect()
        XCTAssertEqual(engine.tapInstalls, 0)

        try mic.start()
        mic.stop()
        mic.reconnect()
        XCTAssertEqual(engine.tapInstalls, 1)
    }

    func testStoppingCancelsAPendingRetry() async throws {
        let engine = FakeAudioInputEngine()
        let h = MicHarness(engine: engine)
        try h.mic.start()
        engine.startError = TestFailure(message: "Device busy")
        engine.simulateConfigurationChange()
        await eventually { h.scheduler.delays == [1] }

        h.mic.stop()
        engine.startError = nil
        h.scheduler.fireAll()

        await settle()
        XCTAssertFalse(engine.hasTap)
        XCTAssertEqual(engine.starts, 1)
    }
}

/// A microphone over a fake engine, with retries run by hand.
@MainActor
final class MicHarness {
    let mic: MicCapture
    let scheduler = ManualScheduler()
    private(set) var errors: [String] = []
    private(set) var recoveries = 0

    init(engine: FakeAudioInputEngine) {
        mic = MicCapture(engine: engine, schedule: scheduler.schedule)
        mic.onError = { [weak self] in self?.errors.append($0) }
        mic.onRecovered = { [weak self] in self?.recoveries += 1 }
    }
}

final class FakeAudioInputEngine: AudioInputEngine {
    var inputFormat: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
    var onConfigurationChange: (() -> Void)?
    var startError: Error?
    /// The format the tap actually delivers, which is the input's when none was asked for.
    private(set) var tapFormats: [AVAudioFormat] = []
    private(set) var requestedTapFormats: [AVAudioFormat?] = []
    private(set) var tapInstalls = 0
    private(set) var tapRemovals = 0
    private(set) var overlappingTapInstalls = 0
    private(set) var starts = 0
    private var tap: ((AVAudioPCMBuffer) -> Void)?

    var hasTap: Bool { tap != nil }

    func installTap(format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer) -> Void) {
        if tap != nil { overlappingTapInstalls += 1 }
        tapInstalls += 1
        requestedTapFormats.append(format)
        if let effective = format ?? inputFormat { tapFormats.append(effective) }
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
