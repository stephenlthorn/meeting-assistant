import AVFoundation
import XCTest

@MainActor
final class CloudTranscriberTests: XCTestCase {
    func testItConnectsWithTheKeyAndStreamingOptions() throws {
        let h = makeHarness()

        h.transcriber.start()
        h.flush()

        let request = try XCTUnwrap(h.sockets.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        let url = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(url.host, "api.deepgram.com")
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["encoding"], "linear16")
        XCTAssertEqual(query["sample_rate"], "16000")
        XCTAssertEqual(query["channels"], "1")
        XCTAssertEqual(query["interim_results"], "true")
        XCTAssertEqual(query["language"], "en-US")
    }

    func testInterimAndFinalResultsBecomeNumberedUtterances() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for (text, isFinal) in [("hel", false), ("hello", false), ("hello there", true), ("next", false)] {
            h.sockets.latest?.serverSends(transcript: text, isFinal: isFinal)
            h.flush()
        }

        await eventually { h.segments.count == 4 }
        XCTAssertEqual(h.segments, [
            TranscriptSegment(utterance: 0, text: "hel", isFinal: false),
            TranscriptSegment(utterance: 0, text: "hello", isFinal: false),
            TranscriptSegment(utterance: 0, text: "hello there", isFinal: true),
            TranscriptSegment(utterance: 1, text: "next", isFinal: false),
        ])
    }

    func testAudioIsSentAsSixteenBitPCM() throws {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.transcriber.append(tone(amplitude: 0.5))
        h.flush()

        let data = try XCTUnwrap(h.sockets.latest?.sentData.first)
        XCTAssertEqual(data.count, 1_600 * 2)
        let firstSample = data.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(Int(firstSample), 16_384, accuracy: 2)
    }

    func testAQuietStreamIsKeptAlive() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.clock.now += 5
        h.scheduler.fire(delay: CloudTranscriber.keepAliveInterval)
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentText, [#"{"type":"KeepAlive"}"#])
    }

    func testNoKeepAliveWhileAudioIsFlowing() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.clock.now += 3
        h.transcriber.append(tone(amplitude: 0.1))
        h.clock.now += 1
        h.scheduler.fire(delay: CloudTranscriber.keepAliveInterval)
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentText, [])
    }

    func testADroppedConnectionReconnectsWithBackoff() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverDrops()
        h.flush()
        XCTAssertEqual(h.sockets.requests.count, 1)
        XCTAssertTrue(h.scheduler.delays.contains(1))
        await eventually { h.notices.last == "Reconnecting to Deepgram…" }

        h.scheduler.fire(delay: 1)
        h.flush()
        XCTAssertEqual(h.sockets.requests.count, 2)

        h.sockets.latest?.serverDrops()
        h.flush()
        XCTAssertTrue(h.scheduler.delays.contains(2))
    }

    func testRepeatedDisconnectsAreReportedOnce() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for delay in [1.0, 2.0, 4.0] {
            h.sockets.latest?.serverDrops(TestFailure(message: "Socket is not connected"))
            h.flush()
            h.scheduler.fire(delay: delay)
            h.flush()
        }
        h.sockets.latest?.serverDrops(TestFailure(message: "Socket is not connected"))
        h.flush()

        await eventually { !h.errors.isEmpty }
        await settle()
        XCTAssertEqual(h.errors, ["Deepgram keeps disconnecting: Socket is not connected"])
    }

    func testAudioIsDroppedQuietlyWhileDisconnected() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverDrops()
        h.flush()

        h.transcriber.append(tone(amplitude: 0.1))
        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentData.count, 0)
        await settle()
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testAReconnectedStreamClearsTheReconnectingNotice() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverDrops()
        h.flush()
        h.scheduler.fire(delay: 1)
        h.flush()

        h.sockets.latest?.serverSends(transcript: "back", isFinal: false)
        h.flush()

        await eventually { h.notices.count == 2 }
        XCTAssertEqual(h.notices, ["Reconnecting to Deepgram…", nil])
    }

    func testStoppingClosesTheStreamAndIgnoresLateResults() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        let socket = h.sockets.latest

        h.transcriber.stop()
        h.flush()
        socket?.serverSends(transcript: "late", isFinal: true)
        h.flush()

        XCTAssertEqual(socket?.sentText, [#"{"type":"CloseStream"}"#])
        XCTAssertEqual(socket?.closed, true)
        await settle()
        XCTAssertTrue(h.segments.isEmpty)
    }

    func testAMissingKeyIsReported() async {
        let h = makeHarness(apiKey: "")

        h.transcriber.start()
        h.flush()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Missing Deepgram API key."])
        XCTAssertTrue(h.sockets.requests.isEmpty)
    }

    // MARK: - Harness

    private final class Harness {
        let transcriber: CloudTranscriber
        let sockets = FakeSocketServer()
        let scheduler = ManualScheduler()
        let clock = TestClock()
        let queue = DispatchQueue(label: "CloudTranscriberTests")
        var segments: [TranscriptSegment] = []
        var errors: [String] = []
        var notices: [String?] = []

        init(apiKey: String) {
            transcriber = CloudTranscriber(apiKey: apiKey, localeIdentifier: "en-US",
                                           connect: sockets.connect, queue: queue,
                                           now: { [clock] in clock.now }, schedule: scheduler.schedule)
        }

        func flush() { queue.sync {} }
    }

    private func makeHarness(apiKey: String = "dg-key") -> Harness {
        let h = Harness(apiKey: apiKey)
        h.transcriber.onSegment = { [unowned h] in h.segments.append($0) }
        h.transcriber.onError = { [unowned h] in h.errors.append($0) }
        h.transcriber.onNotice = { [unowned h] in h.notices.append($0) }
        return h
    }
}

final class FakeSocketServer {
    private(set) var requests: [URLRequest] = []
    private(set) var sockets: [FakeWebSocket] = []

    var latest: FakeWebSocket? { sockets.last }

    func connect(_ request: URLRequest) -> WebSocketConnection {
        requests.append(request)
        let socket = FakeWebSocket()
        sockets.append(socket)
        return socket
    }
}

final class FakeWebSocket: WebSocketConnection {
    private(set) var sentData: [Data] = []
    private(set) var sentText: [String] = []
    private(set) var closed = false
    private var pendingReceive: ((Result<URLSessionWebSocketTask.Message, Error>) -> Void)?

    func send(_ message: URLSessionWebSocketTask.Message, completion: @escaping (Error?) -> Void) {
        switch message {
        case .data(let data): sentData.append(data)
        case .string(let text): sentText.append(text)
        @unknown default: break
        }
        completion(nil)
    }

    func receive(_ completion: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void) {
        pendingReceive = completion
    }

    func close() { closed = true }

    func serverSends(transcript: String, isFinal: Bool) {
        let json = #"{"type":"Results","is_final":\#(isFinal),"channel":{"alternatives":[{"transcript":"\#(transcript)"}]}}"#
        let receive = pendingReceive
        pendingReceive = nil
        receive?(.success(.string(json)))
    }

    func serverDrops(_ error: Error = URLError(.networkConnectionLost)) {
        let receive = pendingReceive
        pendingReceive = nil
        receive?(.failure(error))
    }
}
