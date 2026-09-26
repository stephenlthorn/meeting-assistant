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
    case failure(message: String)

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
        case "error":
            return .failure(message: (object["error"] as? [String: Any])?["message"] as? String ?? "stream error")
        default:
            return nil
        }
    }
}

/// Streaming client for the Claude Messages API. Swift has no official
/// Anthropic SDK, so this calls the REST endpoint with URLSession and parses
/// the Server-Sent Events stream.
struct AnthropicClient: AnswerStreaming {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let maxTokens = 4096

    private static let cutOffNote = "(Answer cut off at the length limit.)"
    private static let refusalNote = "(Claude declined to answer this.)"

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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
        let (bytes, response) = try await session.bytes(for: Self.makeURLRequest(for: request))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AnthropicError.http(status: http.statusCode, body: body)
        }
        var wroteText = false
        for try await line in bytes.lines {
            switch AnthropicStreamEvent.parse(line: line) {
            case .text(let text):
                emit(text)
                wroteText = true
            case .stop(reason: "max_tokens"):
                emit((wroteText ? "\n\n" : "") + Self.cutOffNote)
            case .stop(reason: "refusal"):
                emit((wroteText ? "\n\n" : "") + Self.refusalNote)
            case .failure(let message):
                throw AnthropicError.midStream(message)
            case .stop, nil:
                break
            }
        }
    }
}
