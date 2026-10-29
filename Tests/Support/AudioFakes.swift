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
    let scheduler: ManualScheduler
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
        scheduler = ManualScheduler()
        workspaceNotifications = NotificationCenter()
        screenNotifications = NotificationCenter()
        controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                         makeTranscriber: transcribers.make, answerer: answerer,
                                         now: { [clock] in clock.now }, schedule: scheduler.schedule,
                                         sampleWordDelay: 0, drainWindow: drainWindow,
                                         workspaceNotifications: workspaceNotifications,
                                         notifications: screenNotifications)
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
