import Foundation

/// Minimal streaming client for the Claude Messages API.
///
/// Swift has no official Anthropic SDK, so this calls the REST endpoint directly
/// with URLSession and parses the Server-Sent Events stream. Text deltas are
/// delivered to `onDelta` as they arrive. Stateless: the caller supplies the key
/// and model per request (from AppSettings).
final class LLMClient {
    func stream(apiKey: String,
                model: String,
                system: String,
                user: String,
                onDelta: @escaping (String) -> Void) async throws {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "LLMClient", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No API key. Add one in Settings (⌘,)."])
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        // effort is supported on opus/sonnet/fable but rejected by haiku.
        if !model.contains("haiku") {
            body["output_config"] = ["effort": "low"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            var message = "HTTP \(http.statusCode)"
            var collected = ""
            for try await line in bytes.lines { collected += line }
            if !collected.isEmpty { message += ": \(collected)" }
            throw NSError(domain: "LLMClient", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            switch type {
            case "content_block_delta":
                if let delta = object["delta"] as? [String: Any],
                   (delta["type"] as? String) == "text_delta",
                   let text = delta["text"] as? String {
                    onDelta(text)
                }
            case "error":
                let message = (object["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw NSError(domain: "LLMClient", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: message])
            default:
                break
            }
        }
    }
}
