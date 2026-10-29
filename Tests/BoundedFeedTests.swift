import XCTest

final class BoundedFeedTests: XCTestCase {
    func testAConsumerThatKeepsUpLosesNothing() async {
        let feed = BoundedFeed<Int>(limit: 3)

        let results = [1, 2, 3].map { feed.yield($0) }
        feed.finish()

        XCTAssertEqual(results, [true, true, true])
        let received = await collect(feed)
        XCTAssertEqual(received, [1, 2, 3])
    }

    func testAConsumerThatFallsBehindKeepsTheNewestAndTheProducerIsToldSo() async {
        let feed = BoundedFeed<Int>(limit: 3)

        let results = (1...5).map { feed.yield($0) }
        feed.finish()

        XCTAssertEqual(results, [true, true, true, false, false])
        let received = await collect(feed)
        XCTAssertEqual(received, [3, 4, 5])
    }

    private func collect(_ feed: BoundedFeed<Int>) async -> [Int] {
        var received: [Int] = []
        for await element in feed.stream { received.append(element) }
        return received
    }
}
