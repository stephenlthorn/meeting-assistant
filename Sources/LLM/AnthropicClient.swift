import Foundation

struct AnswerRequest: Equatable, Sendable {
    let apiKey: String
    let model: String
    let system: String
    let user: String
}

/// Streams an answer as text chunks, in order. Cancelling the consuming task
/// cancels the underlying request.
protocol AnswerStreaming {
    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error>
}

/// A failure worded for the overlay: what happened and what to do about it.
struct AnthropicError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let missingKey = AnthropicError(message: "No API key. Add one in Settings.")

    static func http(status: Int, body: String) -> AnthropicError {
        let detail = apiMessage(in: body).map { ": \($0)" } ?? "."
        switch status {
        case 400: return AnthropicError(message: "Anthropic rejected the request (400)" + detail)
        case 401: return AnthropicError(message: "Anthropic rejected the API key (401). Check it in Settings.")
        case 403: return AnthropicError(message: "This API key can't use that model (403). Pick another model in Settings.")
        case 404: return AnthropicError(message: "Model not found (404). Pick another model in Settings.")
        case 429: return AnthropicError(message: "Rate limited by Anthropic (429). Wait a moment and try again.")
        case 529: return AnthropicError(message: "Claude is overloaded right now (529). Try again in a moment.")
        case 500...599: return AnthropicError(message: "Anthropic had a server error (\(status)). Try again in a moment.")
        default: return AnthropicError(message: "Anthropic returned HTTP \(status)" + detail)
        }
    }

    static func midStream(_ message: String) -> AnthropicError {
        AnthropicError(message: "Claude stopped mid-answer: \(message)")
    }

    /// The connection closed with no stop event, so the text may be incomplete.
    static let cutOff = AnthropicError(
        message: "The answer was cut off: the connection closed before Claude finished. Ask again.")

    private static func apiMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

/// The Server-Sent Events this client acts on; everything else is ignored.
enum AnthropicStreamEvent: Equatable {
    case text(String)
    case stop(reason: String)
    /// `message_stop`: the answer is complete.
    case finished
    case failure(message: String, isOverloaded: Bool)

    static func parse(line: String) -> AnthropicStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            guard let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String else { return nil }
            return .stop(reason: reason)
        case "message_stop":
            return .finished
        case "error":
            let error = object["error"] as? [String: Any]
            return .failure(message: error?["message"] as? String ?? "stream error",
                            isOverloaded: error?["type"] as? String == "overloaded_error")
        default:
            return nil
        }
    }
}

/// When and how long to wait before asking again after Claude is overloaded or
/// rate limited. Waits go through `sleep` and randomness through `jitter`, so
/// tests neither wait nor flake.
struct RetryPolicy {
    var maxRetries = 2
    /// The longest wait worth making during a live call; a longer `retry-after`
    /// is reported to the user instead of waited out.
    var maxDelay: TimeInterval = 8
    var baseDelay: TimeInterval = 0.5
    /// A fraction in 0...1 added on top of the backoff, so clients do not retry in step.
    var jitter: () -> Double = { Double.random(in: 0...1) }
    var sleep: (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The wait before retry number `retry` (1 for the first), or nil when the
    /// server asked for longer than `maxDelay`.
    func delay(forRetry retry: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        if let retryAfter { return retryAfter <= maxDelay ? retryAfter : nil }
        return baseDelay * pow(2, Double(retry - 1)) * (1 + jitter())
    }
}

/// A failure worth another try: Claude was overloaded or rate limited before
/// any text reached the overlay.
private struct RetryableFailure: Error {
    let error: AnthropicError
    let retryAfter: TimeInterval?
}

/// Streaming client for the Claude Messages API. Swift has no official
/// Anthropic SDK, so this calls the REST endpoint with URLSession and parses
/// the Server-Sent Events stream.
///
/// A 429 or 529 (or an overloaded error event) is retried up to twice, but only
/// while no text has been emitted, so an answer never restarts under the
/// reader. A stream that closes without a stop event is an error, not a
/// complete answer.
struct AnthropicClient: AnswerStreaming {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxTokens = 4096

    private static let cutOffNote = "(Answer cut off at the length limit.)"
    private static let refusalNote = "(Claude declined to answer this.)"
    private static let retryableStatuses: Set<Int> = [429, 529]

    let session: URLSession
    let retry: RetryPolicy

    init(session: URLSession = .shared, retry: RetryPolicy = RetryPolicy()) {
        self.session = session
        self.retry = retry
    }

    static func makeURLRequest(for request: AnswerRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue(request.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]],
        ]
        // Effort is accepted by Opus and Sonnet but rejected by Haiku 4.5.
        if !request.model.contains("haiku") {
            body["output_config"] = ["effort": "low"]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    func stream(_ request: AnswerRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ request: AnswerRequest, emit: (String) -> Void) async throws {
        guard !request.apiKey.isEmpty else { throw AnthropicError.missingKey }
        var retries = 0
        while true {
            do {
                try await attempt(request, emit: emit)
                return
            } catch let failure as RetryableFailure {
                guard retries < retry.maxRetries,
                      let wait = retry.delay(forRetry: retries + 1, retryAfter: failure.retryAfter) else {
                    throw failure.error
                }
                retries += 1
                try await retry.sleep(wait)
            }
        }
    }

    /// One request. Throws `RetryableFailure` only before any text was emitted.
    private func attempt(_ request: AnswerRequest, emit: (String) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: Self.makeURLRequest(for: request))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            let error = AnthropicError.http(status: http.statusCode, body: body)
            guard Self.retryableStatuses.contains(http.statusCode) else { throw error }
            throw RetryableFailure(error: error, retryAfter: Self.retryAfter(in: http))
        }
        var wroteText = false
        var finished = false
        for try await line in bytes.lines {
            switch AnthropicStreamEvent.parse(line: line) {
            case .text(let text):
                emit(text)
                wroteText = true
            case .stop(reason: "max_tokens"):
                emit((wroteText ? "\n\n" : "") + Self.cutOffNote)
                finished = true
            case .stop(reason: "refusal"):
                emit((wroteText ? "\n\n" : "") + Self.refusalNote)
                finished = true
            case .stop, .finished:
                finished = true
            case .failure(let message, let isOverloaded):
                let error = AnthropicError.midStream(message)
                guard isOverloaded, !wroteText else { throw error }
                throw RetryableFailure(error: error, retryAfter: nil)
            case nil:
                break
            }
        }
        guard finished else { throw AnthropicError.cutOff }
    }

    private static func retryAfter(in response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "retry-after")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .map { max(0, $0) }
    }
}
