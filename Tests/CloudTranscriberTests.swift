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

    func testStoppingAsksTheServerToFinishAndClosesAfterTheDrainWindow() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        let socket = h.sockets.latest

        h.transcriber.stop()
        h.flush()
        XCTAssertEqual(socket?.sentText, [#"{"type":"CloseStream"}"#])
        XCTAssertEqual(socket?.closed, false, "the server still has words to deliver")

        h.scheduler.fire(delay: CloudTranscriber.defaultDrainTimeout)
        h.flush()
        XCTAssertEqual(socket?.closed, true)
    }

    func testResultsThatArriveWhileDrainingAreDelivered() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverSends(transcript: "We should ship in", isFinal: false)
        h.flush()

        h.transcriber.stop()
        h.flush()
        h.sockets.latest?.serverSends(transcript: "May.", isFinal: true, speechFinal: false)
        h.flush()
        h.sockets.latest?.serverDrops(URLError(.networkConnectionLost))
        h.flush()

        await eventually { h.segments.count == 3 }
        XCTAssertEqual(h.segments.last, TranscriptSegment(utterance: 0, text: "May.", isFinal: true))
        XCTAssertEqual(h.sockets.latest?.closed, true)
        XCTAssertEqual(h.sockets.requests.count, 1, "a server close during the drain is not a reason to reconnect")
        XCTAssertTrue(h.errors.isEmpty)
    }

    func testTheServerClosingEndsTheDrainAndFinishesAnOpenUtterance() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverSends(transcript: "last words", isFinal: true, speechFinal: false)
        h.flush()

        h.transcriber.stop()
        h.flush()
        h.sockets.latest?.serverDrops(URLError(.networkConnectionLost))
        h.flush()

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments.last, TranscriptSegment(utterance: 0, text: "last words", isFinal: true))
    }

    func testNothingIsAcceptedAfterTheDrainWindowCloses() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        let socket = h.sockets.latest
        h.transcriber.stop()
        h.flush()
        h.scheduler.fire(delay: CloudTranscriber.defaultDrainTimeout)
        h.flush()

        socket?.serverSends(transcript: "late", isFinal: true)
        h.flush()

        await settle()
        XCTAssertTrue(h.segments.isEmpty)
    }

    func testAudioIsNotSentWhileDraining() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.transcriber.stop()
        h.flush()

        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentData.count, 0)
    }

    func testStartingAgainClosesTheOldStreamAtOnce() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        let old = h.sockets.latest
        h.transcriber.stop()
        h.flush()

        h.transcriber.start()
        h.flush()

        XCTAssertEqual(old?.closed, true)
        XCTAssertEqual(h.sockets.requests.count, 2)
    }

    func testStoppingTwiceAsksTheServerToFinishOnce() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.transcriber.stop()
        h.transcriber.stop()
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentText, [#"{"type":"CloseStream"}"#])
    }

    func testStoppingWhileDisconnectedHasNothingToDrain() {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverDrops()
        h.flush()

        h.transcriber.stop()
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentText, [])
    }

    func testAMissingKeyIsReported() async {
        let h = makeHarness(apiKey: "")

        h.transcriber.start()
        h.flush()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Missing Deepgram API key."])
        XCTAssertTrue(h.sockets.requests.isEmpty)
    }

    // MARK: - Utterances (AUD-4)

    func testAChunkThatIsFinalButNotTheEndOfSpeechKeepsTheUtteranceOpen() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverSends(transcript: "so what would you", isFinal: true, speechFinal: false)
        h.flush()
        h.sockets.latest?.serverSends(transcript: "recommend for sharding?", isFinal: true, speechFinal: true)
        h.flush()

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments, [
            TranscriptSegment(utterance: 0, text: "so what would you", isFinal: false),
            TranscriptSegment(utterance: 0, text: "so what would you recommend for sharding?", isFinal: true),
        ])
    }

    func testInterimTextExtendsWhatWasAlreadyConfirmed() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverSends(transcript: "so what would you", isFinal: true, speechFinal: false)
        h.flush()
        h.sockets.latest?.serverSends(transcript: "recommend", isFinal: false)
        h.flush()
        h.sockets.latest?.serverSends(transcript: "recommend for", isFinal: false)
        h.flush()

        await eventually { h.segments.count == 3 }
        XCTAssertEqual(h.segments.map(\.text), ["so what would you", "so what would you recommend",
                                                "so what would you recommend for"])
        XCTAssertEqual(h.segments.map(\.isFinal), [false, false, false])
        XCTAssertEqual(Set(h.segments.map(\.utterance)), [0])
    }

    func testAnUtteranceEndMessageFinishesTheUtterance() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverSends(transcript: "let me think", isFinal: true, speechFinal: false)
        h.flush()
        h.sockets.latest?.serverSendsUtteranceEnd()
        h.flush()
        h.sockets.latest?.serverSends(transcript: "okay", isFinal: false)
        h.flush()

        await eventually { h.segments.count == 3 }
        XCTAssertEqual(h.segments, [
            TranscriptSegment(utterance: 0, text: "let me think", isFinal: false),
            TranscriptSegment(utterance: 0, text: "let me think", isFinal: true),
            TranscriptSegment(utterance: 1, text: "okay", isFinal: false),
        ])
    }

    func testAnUtteranceEndWithNothingOpenSaysNothing() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverSends(transcript: "done.", isFinal: true, speechFinal: true)
        h.flush()
        h.sockets.latest?.serverSendsUtteranceEnd()
        h.flush()

        await eventually { !h.segments.isEmpty }
        await settle()
        XCTAssertEqual(h.segments, [TranscriptSegment(utterance: 0, text: "done.", isFinal: true)])
    }

    func testAnEndOfSpeechWithNoNewWordsFinishesTheConfirmedText() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.serverSends(transcript: "send it over", isFinal: true, speechFinal: false)
        h.flush()
        h.sockets.latest?.serverSends(transcript: "", isFinal: true, speechFinal: true)
        h.flush()

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments.last, TranscriptSegment(utterance: 0, text: "send it over", isFinal: true))
    }

    func testAConnectionThatDropsMidUtteranceFinishesWhatWasHeard() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.serverSends(transcript: "we could move", isFinal: true, speechFinal: false)
        h.flush()

        h.sockets.latest?.serverDrops()
        h.flush()

        await eventually { h.segments.count == 2 }
        XCTAssertEqual(h.segments.last, TranscriptSegment(utterance: 0, text: "we could move", isFinal: true))
    }

    func testTheStreamAsksForUtteranceEndMessages() throws {
        let h = makeHarness()

        h.transcriber.start()
        h.flush()

        let url = try XCTUnwrap(h.sockets.requests.first?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        let query = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["utterance_end_ms"], "1000")
    }

    // MARK: - Permanent failures (AUD-6)

    func testARejectedKeyStopsReconnectingAndSaysSo() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.handshakeStatusCode = 401
        h.sockets.latest?.serverDrops(TestFailure(message: "There was a bad response from the server."))
        h.flush()
        h.scheduler.fireAll()
        h.flush()

        await eventually { !h.errors.isEmpty }
        await settle()
        XCTAssertEqual(h.errors, ["Deepgram rejected the API key (401). Check it in Settings."])
        XCTAssertEqual(h.sockets.requests.count, 1)
        XCTAssertFalse(h.notices.contains("Reconnecting to Deepgram…"))
    }

    func testAForbiddenKeyIsTreatedTheSameWay() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.handshakeStatusCode = 403
        h.sockets.latest?.serverDrops()
        h.flush()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Deepgram rejected the API key (403). Check it in Settings."])
    }

    func testAnAccountThatNeedsPaymentStopsReconnectingToo() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.handshakeStatusCode = 402
        h.sockets.latest?.serverDrops()
        h.flush()
        h.scheduler.fireAll()
        h.flush()

        await eventually { !h.errors.isEmpty }
        XCTAssertEqual(h.errors, ["Deepgram says this account needs payment or credit (402). Check your Deepgram billing."])
        XCTAssertEqual(h.sockets.requests.count, 1)
    }

    func testAudioIsNotSentAfterAPermanentFailure() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()
        h.sockets.latest?.handshakeStatusCode = 401
        h.sockets.latest?.serverDrops()
        h.flush()

        h.transcriber.append(tone(amplitude: 0.1))
        h.flush()

        XCTAssertEqual(h.sockets.latest?.sentData.count, 0)
    }

    func testOtherStatusesKeepRetrying() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.handshakeStatusCode = 503
        h.sockets.latest?.serverDrops()
        h.flush()
        h.scheduler.fireAll()
        h.flush()

        XCTAssertEqual(h.sockets.requests.count, 2)
    }

    func testItGivesUpAfterTooManyFailuresInARowAndSaysWhatToDo() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for _ in 0..<CloudTranscriber.failuresBeforeGivingUp {
            h.sockets.latest?.serverDrops(TestFailure(message: "Socket is not connected"))
            h.flush()
            h.scheduler.fireAll()
            h.flush()
        }

        await eventually { h.errors.count == 2 }
        XCTAssertEqual(h.errors.last,
                       "Deepgram couldn't be reached after \(CloudTranscriber.failuresBeforeGivingUp) tries: Socket is not connected. Stop listening and start again to retry.")
        XCTAssertEqual(h.sockets.requests.count, CloudTranscriber.failuresBeforeGivingUp)
        XCTAssertEqual(h.notices.last, .some(nil))
    }

    // MARK: - Fatal failures (M1)

    func testAMissingKeyIsFatalAsWellAsReported() async {
        let h = makeHarness(apiKey: "")

        h.transcriber.start()
        h.flush()

        await eventually { !h.fatals.isEmpty }
        XCTAssertEqual(h.fatals, ["Missing Deepgram API key."])
    }

    func testARejectedKeyIsFatalAsWellAsReported() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        h.sockets.latest?.handshakeStatusCode = 401
        h.sockets.latest?.serverDrops()
        h.flush()

        await eventually { !h.fatals.isEmpty }
        XCTAssertEqual(h.fatals, ["Deepgram rejected the API key (401). Check it in Settings."])
        XCTAssertEqual(h.errors, h.fatals, "the same words are shown to the user")
    }

    func testReconnectingTroubleIsOnlyFatalOnceItGivesUp() async {
        let h = makeHarness()
        h.transcriber.start()
        h.flush()

        for _ in 0..<(CloudTranscriber.failuresBeforeGivingUp - 1) {
            h.sockets.latest?.serverDrops(TestFailure(message: "Socket is not connected"))
            h.flush()
            h.scheduler.fireAll()
            h.flush()
        }
        await eventually { h.errors.count == 1 }
        XCTAssertEqual(h.fatals, [], "keeps disconnecting is a warning: it is still retrying")

        h.sockets.latest?.serverDrops(TestFailure(message: "Socket is not connected"))
        h.flush()

        await eventually { h.fatals.count == 1 }
        XCTAssertTrue(h.fatals.first?.hasPrefix("Deepgram couldn't be reached after") ?? false)
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
        var fatals: [String] = []
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
        h.transcriber.onSegment = { [weak h] in h?.segments.append($0) }
        h.transcriber.onError = { [weak h] in h?.errors.append($0) }
        h.transcriber.onFatal = { [weak h] in h?.fatals.append($0) }
        h.transcriber.onNotice = { [weak h] in h?.notices.append($0) }
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
    /// The HTTP status of a refused WebSocket upgrade, when the server gave one.
    var handshakeStatusCode: Int?
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

    /// A Results message. Deepgram reports an end of speech (`speech_final`)
    /// only on a final chunk, and a plain final chunk is not the end of an
    /// utterance; by default the two go together.
    func serverSends(transcript: String, isFinal: Bool, speechFinal: Bool? = nil) {
        let json = #"{"type":"Results","is_final":\#(isFinal),"speech_final":\#(speechFinal ?? isFinal),"channel":{"alternatives":[{"transcript":"\#(transcript)"}]}}"#
        deliver(.string(json))
    }

    func serverSendsUtteranceEnd() {
        deliver(.string(#"{"type":"UtteranceEnd","channel":[0],"last_word_end":2.4}"#))
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message) {
        let receive = pendingReceive
        pendingReceive = nil
        receive?(.success(message))
    }

    func serverDrops(_ error: Error = URLError(.networkConnectionLost)) {
        let receive = pendingReceive
        pendingReceive = nil
        receive?(.failure(error))
    }
}
