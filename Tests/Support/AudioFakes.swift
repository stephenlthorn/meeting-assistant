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
    let clock: TestClock
    let scheduler: ManualScheduler
    let workspaceNotifications: NotificationCenter
    let screenNotifications: NotificationCenter

    init(testCase: XCTestCase, acceptTerms: Bool = true) {
        settings = makeTestSettings(for: testCase, acceptTerms: acceptTerms)
        systemAudio = FakeSystemAudio()
        microphone = FakeMicrophone()
        transcribers = FakeTranscriberFactory()
        clock = TestClock()
        scheduler = ManualScheduler()
        workspaceNotifications = NotificationCenter()
        screenNotifications = NotificationCenter()
        controller = AssistantController(settings: settings, systemAudio: systemAudio, microphone: microphone,
                                         makeTranscriber: transcribers.make, answerer: FakeAnswerer(),
                                         now: { [clock] in clock.now }, schedule: scheduler.schedule,
                                         sampleWordDelay: 0)
    }

    /// Starts listening and waits until both sides are up.
    func startListening(file: StaticString = #filePath, line: UInt = #line) async {
        controller.start()
        await eventually(file: file, line: line) {
            controller.listening == .listening && systemAudio.events.last != "start"
        }
    }
}
