import XCTest

/// How hard the controller tries to bring their side back (round 2: CAP2-6 and
/// the cheap hardening around restarts): a stream that dies at once backs off
/// instead of restarting every second, an error that lands while a restart is
/// starting is not lost, and a capture call that never returns cannot block
/// every later Stop and Start.
@MainActor
final class SystemAudioRecoveryTests: XCTestCase {
    // MARK: - Backoff only resets after real audio (CAP2-6)

    func testAStreamThatDiesAsSoonAsItRestartsBacksOffLongerEachTime() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        var delays: [TimeInterval] = []

        for _ in 0..<4 {
            h.systemAudio.onError?("The stream died at once")
            delays += h.scheduler.delays
            await restart(h)
        }

        XCTAssertEqual(delays, [1, 2, 4, 8])
    }

    func testAStreamThatDeliveredAudioForHalfAMinuteStartsTheBackoffOver() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The stream died")
        await restart(h)
        h.systemAudio.onError?("The stream died at once")
        XCTAssertEqual(h.scheduler.delays, [2])
        await restart(h)

        h.systemAudio.onBuffer?(silentBuffer())
        h.clock.now = h.clock.now.addingTimeInterval(AssistantController.healthyStreamDuration)
        h.systemAudio.onError?("The stream died after a good run")

        XCTAssertEqual(h.scheduler.delays, [1], "a stream that ran well is not held to its earlier failures")
    }

    func testHalfAMinuteWithoutAnyAudioIsNotAGoodRun() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The stream died")
        await restart(h)

        h.clock.now = h.clock.now.addingTimeInterval(AssistantController.healthyStreamDuration * 2)
        h.systemAudio.onError?("The stream died without ever delivering anything")

        XCTAssertEqual(h.scheduler.delays, [2])
    }

    func testAWakeStillRestartsAtOnceWhateverTheBackoff() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        for _ in 0..<3 {
            h.systemAudio.onError?("The stream died at once")
            await restart(h)
        }
        h.systemAudio.onError?("The stream died at once")

        h.workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)

        await eventually { h.systemAudio.events.filter { $0 == "started" }.count == 5 }
    }

    // MARK: - An error while a restart is starting is not lost

    func testAStreamThatDiesWhileItsRestartIsStartingDoesNotCountAsRestarted() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.holdsStart = true
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.last == "start" }

        h.systemAudio.onError?("It died again before it was up")
        h.systemAudio.releaseStart()

        await eventually { h.scheduler.delays == [2] }
        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
    }

    func testAStopThatCannotBeUndoneWhileARestartIsStartingGivesUpOnTheirSide() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.holdsStart = true
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.last == "start" }

        h.systemAudio.onError?(CaptureFailure(message: "The user stopped the stream", isRetryable: false))
        h.systemAudio.releaseStart()

        await eventually { h.controller.status == "Listening (on-device, your side only)" }
        XCTAssertEqual(h.controller.problems.map(\.message), ["Meeting audio stopped: The user stopped the stream"])
        XCTAssertTrue(h.scheduler.delays.isEmpty)
    }

    func testAnErrorFromAnEarlierSessionDuringARestartIsIgnored() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        let old = h.systemAudio.onError
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.holdsStart = true
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.last == "start" }
        h.controller.stop()

        old?("A stray error from the stream that was replaced")
        h.systemAudio.releaseStart()
        await settle()

        XCTAssertEqual(h.controller.status, "Stopped")
    }

    // MARK: - A capture call that never returns

    func testAHungStopDoesNotBlockTheNextStart() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.holdsStop = true
        h.controller.stop()
        await eventually { h.systemAudio.events.last == "stop" }

        h.controller.start()
        await settle()
        XCTAssertEqual(h.systemAudio.events.filter { $0 == "start" }.count, 1, "still waiting behind the stop")
        h.timeoutScheduler.fire(delay: AssistantController.systemAudioStopTimeout)

        await eventually { h.systemAudio.events.filter { $0 == "start" }.count == 2 }
        await eventually { h.controller.status == "Listening (on-device)" }
    }

    func testAHungStartIsGivenUpOnAndSaidSo() async {
        let h = LifecycleHarness(testCase: self)
        h.systemAudio.holdsStart = true
        h.controller.start()
        await eventually { h.systemAudio.events == ["start"] }

        h.timeoutScheduler.fire(delay: AssistantController.systemAudioStartTimeout)

        await eventually { !h.controller.problems.isEmpty }
        XCTAssertEqual(h.controller.problems.map(\.message),
                       ["Couldn't capture meeting audio: Starting meeting audio capture took too long."])
        XCTAssertEqual(h.controller.status, "Listening (on-device, your side only)")
        h.systemAudio.releaseStart()
    }

    func testAHungStartOnARestartCountsAsAFailedAttempt() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()
        h.systemAudio.onError?("The display went to sleep")
        h.systemAudio.holdsStart = true
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.last == "start" }

        h.timeoutScheduler.fire(delay: AssistantController.systemAudioStartTimeout)

        await eventually { h.scheduler.delays == [2] }
        XCTAssertEqual(h.controller.status, "Listening (on-device, reconnecting their side)")
        h.systemAudio.releaseStart()
    }

    func testACallThatFinishesInTimeIsNotJudgedLate() async {
        let h = LifecycleHarness(testCase: self)
        await h.startListening()

        h.timeoutScheduler.fireAll()
        await settle()

        XCTAssertEqual(h.controller.status, "Listening (on-device)")
        XCTAssertEqual(h.controller.problems, [])
    }

    // MARK: - Helpers

    /// Fires the pending backoff and waits for the stream to be up again.
    private func restart(_ h: LifecycleHarness) async {
        let started = h.systemAudio.events.filter { $0 == "started" }.count
        h.scheduler.fireAll()
        await eventually { h.systemAudio.events.filter { $0 == "started" }.count == started + 1 }
        await eventually { h.controller.status == "Listening (on-device)" }
    }
}
