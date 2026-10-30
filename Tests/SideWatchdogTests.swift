import XCTest

/// The judgement alone: readings and times in, a verdict out. The controller
/// tests cover what happens next.
final class SideWatchdogTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)

    // MARK: - Capture that goes silent

    func testAudioThatKeepsArrivingIsHealthy() {
        var h = Scenario(start: start)

        for _ in 0..<60 {
            XCTAssertNil(h.step(5, buffers: 40))
        }
    }

    func testNoBuffersForThirtySecondsRestartsCapture() {
        var h = Scenario(start: start)

        for _ in 0..<5 { XCTAssertNil(h.step(5)) }
        XCTAssertEqual(h.step(5), .restartCapture)
    }

    func testAfterARestartCaptureGetsAFullStallPeriodBeforeBeingJudgedAgain() {
        var h = Scenario(start: start)
        h.run(30)

        for _ in 0..<5 { XCTAssertNil(h.step(5)) }
        XCTAssertEqual(h.step(5), .captureStillSilent)
    }

    func testAStreamThatStaysSilentIsReportedOnceAndNotRestartedForever() {
        var h = Scenario(start: start)
        h.run(60)

        XCTAssertEqual(h.verdicts(during: 600), [])
    }

    func testAudioReturningAfterAReportClearsItAndRestoresTheRestartBudget() {
        var h = Scenario(start: start)
        h.run(60)

        XCTAssertEqual(h.step(5, buffers: 10), .captureResumed)
        XCTAssertNil(h.step(5, buffers: 10))
        XCTAssertEqual(h.verdicts(during: 30), [.restartCapture])
    }

    func testAudioReturningAfterAQuietRestartIsNotWorthMentioning() {
        var h = Scenario(start: start)
        h.run(30)

        XCTAssertNil(h.step(5, buffers: 10))
        XCTAssertEqual(h.verdicts(during: 30), [.restartCapture], "the next stall is treated as a first one")
    }

    func testRearmingGivesCaptureAFreshStartingPoint() {
        var h = Scenario(start: start)
        h.run(20)

        h.rearm()

        XCTAssertEqual(h.verdicts(during: 29), [])
        XCTAssertEqual(h.verdicts(during: 5), [.restartCapture])
    }

    func testRearmingKeepsTheMemoryOfAnEarlierRestart() {
        var h = Scenario(start: start)
        h.run(30)
        h.rearm()

        XCTAssertEqual(h.verdicts(during: 30), [.captureStillSilent])
    }

    func testItKnowsWhetherAudioArrivedSinceTheLastCheck() {
        var h = Scenario(start: start)

        _ = h.step(5, buffers: 10)
        XCTAssertTrue(h.watchdog.isHearingAudio)
        _ = h.step(5)
        XCTAssertFalse(h.watchdog.isHearingAudio)
    }

    // MARK: - A voice that is never written down

    func testAMinuteOfVoiceAndNoTextRestartsTheTranscriber() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 120, buffers: 40, voice: 4), [.restartTranscriber, .transcriberStillSilent])
    }

    func testQuietAudioIsNotAProblemHoweverLongItLasts() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 3_600, buffers: 40, voice: 0), [])
    }

    func testAFewSecondsOfNoiseInAMinuteIsNotAProblem() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 60, buffers: 40, voice: 0.3), [])
    }

    func testTextInTheWindowKeepsItHealthy() {
        var h = Scenario(start: start)

        for _ in 0..<120 {
            _ = h.step(5, buffers: 40, voice: 4, text: true)
        }

        XCTAssertEqual(h.collected, [])
    }

    func testTheSecondSilentMinuteAfterTheRestartTellsTheUserOnce() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 600, buffers: 40, voice: 4), [.restartTranscriber, .transcriberStillSilent])
    }

    func testTextAfterTheReportClearsItAndRestoresTheRestart() {
        var h = Scenario(start: start)
        XCTAssertEqual(h.verdicts(during: 120, buffers: 40, voice: 4), [.restartTranscriber, .transcriberStillSilent])

        XCTAssertTrue(h.watchdog.noteText(), "it says a report was standing, so the owner can clear it")
        XCTAssertFalse(h.watchdog.noteText())

        XCTAssertEqual(h.verdicts(during: 180, buffers: 40, voice: 4), [.restartTranscriber, .transcriberStillSilent],
                       "the minute the text arrived in does not count as silent")
    }

    func testAWindowIsJudgedOnlyOnceItIsAMinuteLong() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 55, buffers: 40, voice: 4), [])
        XCTAssertEqual(h.verdicts(during: 5, buffers: 40, voice: 4), [.restartTranscriber])
    }

    // MARK: - A transcriber that is still getting ready (CAP2-3)

    func testTextIsNotJudgedWhileTheTranscriberIsPreparing() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 600, buffers: 40, voice: 4, judgesText: false), [])
    }

    func testCaptureIsStillJudgedWhileTheTranscriberIsPreparing() {
        var h = Scenario(start: start)

        XCTAssertEqual(h.verdicts(during: 30, judgesText: false), [.restartCapture])
    }

    func testTheTextWindowStartsFreshOnceThePreparingIsOver() {
        var h = Scenario(start: start)
        _ = h.verdicts(during: 600, buffers: 40, voice: 4, judgesText: false)

        XCTAssertEqual(h.verdicts(during: 55, buffers: 40, voice: 4), [], "the minutes spent preparing do not count")
        XCTAssertEqual(h.verdicts(during: 5, buffers: 40, voice: 4), [.restartTranscriber])
    }
}

/// A watchdog fed readings at fixed steps, like the controller's timer does.
private struct Scenario {
    var watchdog: SideWatchdog
    private(set) var now: Date
    private var reading = AudioMeter.Reading(buffers: 0, voicedSeconds: 0)
    private(set) var collected: [SideWatchdog.Verdict] = []

    init(start: Date) {
        now = start
        watchdog = SideWatchdog(at: start, reading: reading)
    }

    /// One check, `seconds` later, with that much new audio.
    @discardableResult
    mutating func step(_ seconds: TimeInterval, buffers: Int = 0, voice: TimeInterval = 0,
                       text: Bool = false, judgesText: Bool = true) -> SideWatchdog.Verdict? {
        now = now.addingTimeInterval(seconds)
        reading = AudioMeter.Reading(buffers: reading.buffers + buffers,
                                     voicedSeconds: reading.voicedSeconds + voice)
        if text { _ = watchdog.noteText() }
        let verdict = watchdog.check(reading, at: now, judgesText: judgesText)
        if let verdict { collected.append(verdict) }
        return verdict
    }

    /// Checks every five seconds, returning only what the watchdog said.
    mutating func verdicts(during seconds: TimeInterval, buffers: Int = 0, voice: TimeInterval = 0,
                           judgesText: Bool = true) -> [SideWatchdog.Verdict] {
        var said: [SideWatchdog.Verdict] = []
        for _ in 0..<Int(seconds / 5) {
            if let verdict = step(5, buffers: buffers, voice: voice, judgesText: judgesText) { said.append(verdict) }
        }
        return said
    }

    mutating func run(_ seconds: TimeInterval) {
        _ = verdicts(during: seconds)
    }

    mutating func rearm() {
        watchdog.rearm(at: now, reading: reading)
    }
}
