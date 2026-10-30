import Foundation

/// A queue between a capture thread and a consumer that may fall behind. When
/// it does, the oldest elements are dropped so memory stays bounded and live
/// transcription catches up to the present instead of lagging further.
struct BoundedFeed<Element> {
    let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    init(limit: Int) {
        (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(limit))
    }

    /// Queues `element`. Returns false when an older element had to be dropped to make room.
    @discardableResult
    func yield(_ element: Element) -> Bool {
        if case .dropped = continuation.yield(element) { return false }
        return true
    }

    func finish() {
        continuation.finish()
    }
}
