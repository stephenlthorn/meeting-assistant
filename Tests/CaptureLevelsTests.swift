import XCTest

@MainActor
final class CaptureLevelsTests: XCTestCase {
    func testALevelShowsAtOnceAndFallsAwayGradually() {
        let levels = CaptureLevels()
        levels.setActive(.them, true)

        levels.update(.them, rms: 0.1)
        let peak = levels.them
        XCTAssertEqual(peak, AudioMath.meterPosition(forRMS: 0.1), accuracy: 0.0001)

        levels.update(.them, rms: 0)
        XCTAssertLessThan(levels.them, peak)
        XCTAssertGreaterThan(levels.them, 0, "it eases down instead of dropping")

        for _ in 0..<40 { levels.update(.them, rms: 0) }
        XCTAssertEqual(levels.them, 0, accuracy: 0.01)
    }

    func testALouderBufferRaisesTheLevelEvenWhileItIsStillFalling() {
        let levels = CaptureLevels()
        levels.setActive(.you, true)
        levels.update(.you, rms: 0.1)
        levels.update(.you, rms: 0)

        levels.update(.you, rms: 0.3)

        XCTAssertEqual(levels.you, AudioMath.meterPosition(forRMS: 0.3), accuracy: 0.0001)
    }

    func testTheTwoSidesAreIndependent() {
        let levels = CaptureLevels()
        levels.setActive(.them, true)
        levels.setActive(.you, true)

        levels.update(.them, rms: 0.2)

        XCTAssertGreaterThan(levels.them, 0)
        XCTAssertEqual(levels.you, 0)
    }

    func testASideThatIsNotCapturingIgnoresLevelsStillOnTheirWay() {
        let levels = CaptureLevels()

        levels.update(.them, rms: 0.2)

        XCTAssertEqual(levels.them, 0)
    }

    func testASideThatStopsCapturingDropsToZeroAtOnce() {
        let levels = CaptureLevels()
        levels.setActive(.them, true)
        levels.update(.them, rms: 0.2)

        levels.setActive(.them, false)
        levels.update(.them, rms: 0.2)

        XCTAssertEqual(levels.them, 0)
    }

    func testSilencingASideWhoseAudioHasStoppedArrivingZeroesItAtOnce() {
        let levels = CaptureLevels()
        levels.setActive(.you, true)
        levels.update(.you, rms: 0.2)

        levels.silence(.you)

        XCTAssertEqual(levels.you, 0)
        levels.update(.you, rms: 0.2)
        XCTAssertGreaterThan(levels.you, 0, "it is still capturing, so it comes back with the audio")
    }
}
