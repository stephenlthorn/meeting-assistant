import XCTest

/// Q1 effort and fallback, and Q2 prompt caching: what the request body and headers look like.
final class AnthropicRequestShapeTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.respond = nil
        super.tearDown()
    }

    // MARK: - Effort

    func testEffortFollowsTheCachedCapabilityNotTheModelName() throws {
        let allowed = try body(model: "claude-haiku-5-5", supportsEffort: true)
        let refused = try body(model: "claude-sonnet-5-5", supportsEffort: false)

        XCTAssertEqual((allowed["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(refused["output_config"])
    }

    func testWithoutACapabilityTheConservativeRuleKeepsEffortOffOlderFourFiveModels() throws {
        XCTAssertNil(try body(model: "claude-haiku-4-5")["output_config"])
        XCTAssertNil(try body(model: "claude-sonnet-4-5")["output_config"])
        XCTAssertNil(try body(model: "claude-sonnet-4-5-20250929")["output_config"])
    }

    func testWithoutACapabilityEveryOtherModelGetsLowEffort() throws {
        for model in ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-2"] {
            XCTAssertEqual((try body(model: model)["output_config"] as? [String: String])?["effort"], "low", model)
        }
    }

    func testSamplingParametersAndThinkingAreNeverSent() throws {
        for model in ["claude-haiku-5-5", "claude-opus-5-5", "claude-haiku-4-5"] {
            let sent = try body(model: model)
            for key in ["temperature", "top_p", "top_k", "thinking"] {
                XCTAssertNil(sent[key], "\(key) for \(model)")
            }
        }
    }

    // MARK: - Server-side fallback

    func testTheFallbackHeaderAndBodyAreSentOnlyForTheModelsThatSupportIt() throws {
        let supported = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-fable-5-2"]
        for model in supported {
            let urlRequest = try AnthropicClient.makeURLRequest(for: request(model: model))
            XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01", model)
            XCTAssertEqual(try body(model: model)["fallbacks"] as? String, "default", model)
        }
        for model in ["claude-haiku-5-5", "claude-haiku-4-5", "claude-sonnet-5", "claude-sonnet-4-5", "claude-opus-4-5"] {
            let urlRequest = try AnthropicClient.makeURLRequest(for: request(model: model))
            XCTAssertNil(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), model)
            XCTAssertNil(try body(model: model)["fallbacks"], model)
        }
    }

    func testAStreamWithAFallbackBlockStillYieldsAllTheText() async throws {
        let events = [
            #"{"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-5-5"}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Before "}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":"claude-opus-5-5","to":"claude-sonnet-5-5"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"some_future_block"}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"future_delta","value":"x"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":3,"delta":{"type":"text_delta","text":"after."}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ]
        let body = events.map { "event: x\ndata: \($0)\n\n" }.joined()
        StubURLProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                             headerFields: ["content-type": "text/event-stream"])!, Data(body.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AnthropicClient(session: URLSession(configuration: configuration), retry: RetryPolicy(sleep: { _ in }))

        var text = ""
        for try await chunk in client.stream(request(model: "claude-opus-5-5")) { text += chunk }

        XCTAssertEqual(text, "Before after.")
    }

    // MARK: - Prompt caching

    func testTheSystemPromptIsATextBlockMarkedForCachingAndTheUserMessageStaysSeparate() throws {
        let sent = try body(model: "claude-haiku-5-5", system: "Stable prompt.", user: "Transcript excerpt")

        let blocks = try XCTUnwrap(sent["system"] as? [[String: Any]])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.last?["type"] as? String, "text")
        XCTAssertEqual(blocks.last?["text"] as? String, "Stable prompt.")
        XCTAssertEqual((blocks.last?["cache_control"] as? [String: String])?["type"], "ephemeral")
        let messages = try XCTUnwrap(sent["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Transcript excerpt"]])
        let serializedSystem = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        XCTAssertFalse(serializedSystem.contains("Transcript excerpt"), "volatile text must stay after the breakpoint")
    }

    func testSummaryRequestsCacheTheirSystemPromptToo() throws {
        let sent = try body(model: "claude-sonnet-5-5",
                            system: SummaryPrompt.system(extraInstructions: "Write in Spanish."),
                            user: SummaryPrompt.user(SummaryInput(transcript: "Them: hi", isPartial: false)))

        let blocks = try XCTUnwrap(sent["system"] as? [[String: Any]])
        XCTAssertNotNil(blocks.last?["cache_control"])
        XCTAssertFalse((blocks.last?["text"] as? String ?? "").contains("Them: hi"))
    }

    func testTheSameRequestAlwaysSerializesItsCachedPrefixIdentically() throws {
        let system = Profile.sales.systemPrompt + "\n\nAdditional instructions from the user:\nMention SOC 2."
        let first = try AnthropicClient.makeURLRequest(for: request(model: "claude-haiku-5-5", system: system, user: "one"))
        let second = try AnthropicClient.makeURLRequest(for: request(model: "claude-haiku-5-5", system: system, user: "two"))

        XCTAssertEqual(try systemBytes(first), try systemBytes(second))
        XCTAssertNotEqual(first.httpBody, second.httpBody)
    }

    // MARK: - Helpers

    private func request(model: String, system: String = "Be brief.", user: String = "Transcript here",
                         supportsEffort: Bool? = nil) -> AnswerRequest {
        AnswerRequest(apiKey: "sk-test", model: model, system: system, user: user, supportsEffort: supportsEffort)
    }

    private func body(model: String, system: String = "Be brief.", user: String = "Transcript here",
                      supportsEffort: Bool? = nil) throws -> [String: Any] {
        let urlRequest = try AnthropicClient.makeURLRequest(
            for: request(model: model, system: system, user: user, supportsEffort: supportsEffort))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
    }

    private func systemBytes(_ urlRequest: URLRequest) throws -> Data {
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: XCTUnwrap(sent["system"]), options: [.sortedKeys])
    }
}
