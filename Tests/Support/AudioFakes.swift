import AVFoundation
import XCTest

/// A controller wired to fakes at every system boundary, for tests of the
/// capture and transcription lifecycle.
@MainActor
struct LifecycleHarness {
    let controller: AssistantController
    let settings: AppSettings
    let systemAudio: FakeSystemAudio
    let microphone: FakeMicrophone
    let transcribers: FakeTranscriberFactory
    let answerer: FakeAnswerer
    let clock: TestClock
    let meterClock: MeterClock
    let scheduler: ManualScheduler
    /// The health checks' timer, kept apart so the restart and drain timers stay countable.
    let watchdogScheduler: ManualScheduler
    /// The limits on system audio calls that might never return, kept apart for the same reason.
    let timeoutScheduler: ManualScheduler
    let workspaceNotifications: NotificationCenter
    let screenNotifications: NotificationCenter

    init(testCase: XCTestCase, acceptTerms: Bool = true,
         drainWindow: TimeInterval = AssistantController.defaultDrainWindow) {
        settings = makeTestSettings(for: testCase, acceptTerms: acceptTerms)
        systemAudio = FakeSystemAudio()
        microphone = FakeMicrophone()
        transcribers = FakeTranscriberFactory()
        answerer = FakeAnswerer()
        clock = TestClock()
        meterClock = MeterClock()
        scheduler = ManualScheduler()
        watchdogScheduler = ManualScheduler()
        timeoutScheduler = ManualScheduler()
        workspaceNotifications = NotificationCenter()
        screenNotifications = NotificationCenter()
        controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                         makeTranscriber: transcribers.make, answerer: answerer,
                                         now: { [clock] in clock.now }, schedule: scheduler.schedule,
                                         sampleWordDelay: 0, drainWindow: drainWindow,
                                         workspaceNotifications: workspaceNotifications,
                                         notifications: screenNotifications,
                                         meterClock: { [meterClock] in meterClock.seconds },
                                         watchdogSchedule: watchdogScheduler.schedule,
                                         timeoutSchedule: timeoutScheduler.schedule)
    }

    /// Lets `seconds` go by in the health checks' own steps. Every step delivers
    /// a quiet buffer to the sides in `hearing` and `voiced` seconds of speech
    /// to the sides in `talking`; a side in neither hears nothing at all.
    func pass(_ seconds: TimeInterval, hearing: [Speaker] = [], talking: [Speaker] = [],
              voiced: TimeInterval = 4) async {
        for _ in 0..<Int(seconds / AssistantController.watchdogInterval) {
            clock.now = clock.now.addingTimeInterval(AssistantController.watchdogInterval)
            for speaker in hearing { deliver(silentBuffer(), to: speaker) }
            for speaker in talking { deliver(speech(seconds: voiced), to: speaker) }
            watchdogScheduler.fireAll()
            await mainQueueDrained()
        }
    }

    func deliver(_ buffer: AVAudioPCMBuffer, to speaker: Speaker) {
        if speaker == .them { systemAudio.onBuffer?(buffer) } else { microphone.onBuffer?(buffer) }
    }

    /// Waits for everything already queued for the main thread, which is how
    /// scheduled work reaches the controller.
    func mainQueueDrained() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Starts listening and waits until both sides are up.
    func startListening(file: StaticString = #filePath, line: UInt = #line) async {
        controller.start()
        await eventually(file: file, line: line) {
            controller.listening == .listening && systemAudio.events.last != "start"
        }
    }
}

/// Like `ManualScheduler`, but safe to call from background tasks.
final class ThreadSafeScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(delay: TimeInterval, work: () -> Void)] = []

    var delays: [TimeInterval] { lock.withLock { pending.map(\.delay) } }

    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        lock.withLock { pending.append((delay, work)) }
    }

    func fireAll() {
        let due = lock.withLock { () -> [(delay: TimeInterval, work: () -> Void)] in
            defer { pending = [] }
            return pending
        }
        due.forEach { $0.work() }
    }
}

/// Audio at speech level that lasts `seconds`, in one buffer.
func speech(seconds: TimeInterval, amplitude: Float = 0.1) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let frames = AVAudioFrameCount(16_000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = amplitude }
    return buffer
}
