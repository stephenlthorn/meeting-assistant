import XCTest

final class AnthropicClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.respond = nil
        super.tearDown()
    }

    // MARK: - Request

    func testRequestCarriesTheKeyVersionAndAStreamingBody() throws {
        let urlRequest = try AnthropicClient.makeURLRequest(for: request(model: "claude-sonnet-5"))

        XCTAssertEqual(urlRequest.url, URL(string: "https://api.anthropic.com/v1/messages"))
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "content-type"), "application/json")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["system"] as? String, "Be brief.")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Transcript here"]])
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
    }

    func testHaikuRequestsLeaveOutEffortBecauseHaikuRejectsIt() throws {
        let urlRequest = try AnthropicClient.makeURLRequest(for: request(model: "claude-haiku-4-5"))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertNil(body["output_config"])
    }

    // MARK: - Stream events

    func testTextDeltasAreParsed() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        XCTAssertEqual(AnthropicStreamEvent.parse(line: line), .text("Hi"))
    }

    func testPingsThinkingAndEventNameLinesAreIgnored() {
        XCTAssertNil(AnthropicStreamEvent.parse(line: "event: content_block_delta"))
        XCTAssertNil(AnthropicStreamEvent.parse(line: #"data: {"type":"ping"}"#))
        XCTAssertNil(AnthropicStreamEvent.parse(
            line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#))
    }

    func testTheStopReasonIsParsed() {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":4096}}"#
        XCTAssertEqual(AnthropicStreamEvent.parse(line: line), .stop(reason: "max_tokens"))
    }

    func testErrorEventsAreParsed() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(AnthropicStreamEvent.parse(line: line), .failure(message: "Overloaded"))
    }

    // MARK: - Error messages

    func testHTTPErrorsReadAsPlainGuidance() {
        XCTAssertEqual(AnthropicError.http(status: 401, body: "").message,
                       "Anthropic rejected the API key (401). Check it in Settings.")
        XCTAssertEqual(AnthropicError.http(status: 404, body: "").message,
                       "Model not found (404). Pick another model in Settings.")
        XCTAssertEqual(AnthropicError.http(status: 429, body: "").message,
                       "Rate limited by Anthropic (429). Wait a moment and try again.")
        XCTAssertEqual(AnthropicError.http(status: 529, body: "").message,
                       "Claude is overloaded right now (529). Try again in a moment.")
        XCTAssertEqual(AnthropicError.http(status: 502, body: "").message,
                       "Anthropic had a server error (502). Try again in a moment.")
    }

    func testBadRequestErrorsIncludeTheAPIsExplanation() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}"#
        XCTAssertEqual(AnthropicError.http(status: 400, body: body).message,
                       "Anthropic rejected the request (400): max_tokens: too large")
    }

    // MARK: - Streaming

    func testTheAnswerStreamsTextInOrder() async throws {
        stub(status: 200, sse: [
            #"{"type":"message_start","message":{"id":"msg_1"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ])

        let text = try await collect(client().stream(request(model: "claude-haiku-4-5")))

        XCTAssertEqual(text, "Hello world")
    }

    func testACutOffAnswerSaysSo() async throws {
        stub(status: 200, sse: [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"- first point"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ])

        let text = try await collect(client().stream(request(model: "claude-haiku-4-5")))

        XCTAssertEqual(text, "- first point\n\n(Answer cut off at the length limit.)")
    }

    func testARefusalSaysSo() async throws {
        stub(status: 200, sse: [#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#])

        let text = try await collect(client().stream(request(model: "claude-sonnet-5")))

        XCTAssertEqual(text, "(Claude declined to answer this.)")
    }

    func testAnHTTPErrorEndsTheStreamWithAReadableMessage() async {
        StubURLProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }

        do {
            _ = try await collect(client().stream(request(model: "claude-haiku-4-5")))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Anthropic rejected the API key (401). Check it in Settings.")
        }
    }

    func testAMidStreamErrorEndsTheStreamAfterTheTextSoFar() async {
        stub(status: 200, sse: [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ])
        var received = ""

        do {
            for try await chunk in client().stream(request(model: "claude-haiku-4-5")) { received += chunk }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(received, "Hi")
            XCTAssertEqual(error.localizedDescription, "Claude stopped mid-answer: Overloaded")
        }
    }

    func testAMissingKeyFailsWithoutSendingARequest() async {
        var sent = false
        StubURLProtocol.respond = { request in
            sent = true
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await collect(client().stream(AnswerRequest(apiKey: "", model: "claude-haiku-4-5",
                                                                system: "s", user: "u")))
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(sent)
            XCTAssertEqual(error.localizedDescription, "No API key. Add one in Settings.")
        }
    }

    // MARK: - Helpers

    private func request(model: String) -> AnswerRequest {
        AnswerRequest(apiKey: "sk-test", model: model, system: "Be brief.", user: "Transcript here")
    }

    private func client() -> AnthropicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AnthropicClient(session: URLSession(configuration: configuration))
    }

    private func stub(status: Int, sse events: [String]) {
        let body = events.map { "event: x\ndata: \($0)\n\n" }.joined()
        StubURLProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                             headerFields: ["content-type": "text/event-stream"])!,
             Data(body.utf8))
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await chunk in stream { text += chunk }
        return text
    }
}

final class StubURLProtocol: URLProtocol {
    static var respond: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let respond = StubURLProtocol.respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (response, data) = respond(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
