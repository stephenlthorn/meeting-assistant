import XCTest

final class TranscriberSlotTests: XCTestCase {
    func testAudioGoesToWhicheverTranscriberIsCurrent() {
        let slot = TranscriberSlot()
        let first = FakeTranscriber()
        let second = FakeTranscriber()

        slot.set(first)
        slot.append(silentBuffer())
        slot.set(second)
        slot.append(silentBuffer())
        slot.set(nil)
        slot.append(silentBuffer())

        XCTAssertEqual(first.appended, 1)
        XCTAssertEqual(second.appended, 1)
    }

    func testSwappingTranscribersWhileAudioArrivesFromOtherThreadsIsSafe() {
        let slot = TranscriberSlot()
        let transcribers = (0..<4).map { _ in FakeTranscriber() }
        let buffer = silentBuffer()

        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for step in 0..<5_000 {
                if worker == 0 {
                    slot.set(step.isMultiple(of: 5) ? nil : transcribers[step % 4])
                } else {
                    slot.append(buffer)
                }
            }
        }

        XCTAssertGreaterThan(transcribers.map(\.appended).reduce(0, +), 0)
    }
}
