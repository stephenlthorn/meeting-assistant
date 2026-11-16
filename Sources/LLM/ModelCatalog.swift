import Foundation

/// One model the picker can offer.
struct ModelInfo: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    /// Seconds since 1970 from the API's `created_at`; only used to sort newest first.
    let created: TimeInterval
    /// Whether the model accepts `effort: low`, from `capabilities.effort`; nil when not known.
    let acceptsLowEffort: Bool?
}

/// A row in the model picker.
struct ModelOption: Equatable, Identifiable {
    let id: String
    let name: String
}

/// The models Settings offers, read from the Models API so the list cannot go
/// stale. The last good answer is cached in UserDefaults and a built-in list
/// stands in when there has never been one (no key, or no network). Only the
/// API key leaves the Mac, and no call content is involved.
@MainActor
final class ModelCatalog {
    static let refreshInterval: TimeInterval = 3600
    static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    private static let pageSize = 1000
    /// A runaway `has_more` must not loop forever.
    private static let maxPages = 10
    private static let cacheKey = "llm.modelCatalog"
    private static let fetchedAtKey = "llm.modelCatalogFetchedAt"

    /// Shown until the API has answered once. All three take effort.
    static let fallback: [ModelInfo] = [
        ModelInfo(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", created: 3, acceptsLowEffort: true),
        ModelInfo(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", created: 2, acceptsLowEffort: true),
        ModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", created: 1, acceptsLowEffort: true),
    ]

    private(set) var models: [ModelInfo]
    /// The list came from the Models API (this launch or an earlier one), not the built-in one.
    private(set) var isFromAPI: Bool

    private let defaults: UserDefaults
    private let session: URLSession
    private let now: () -> Date

    init(defaults: UserDefaults, session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.session = session
        self.now = now
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([ModelInfo].self, from: data), !cached.isEmpty {
            models = cached
            isFromAPI = true
        } else {
            models = Self.fallback
            isFromAPI = false
        }
    }

    func displayName(for id: String) -> String? {
        models.first(where: { $0.id == id })?.displayName
    }

    /// Whether `effort: low` is safe to send, or nil when the model is not in the list.
    func supportsEffort(_ id: String) -> Bool? {
        models.first(where: { $0.id == id })?.acceptsLowEffort
    }

    /// Asks the API for the list unless it did within the last hour (`force` skips
    /// that, for a newly saved key). Returns whether the list changed; any
    /// failure leaves the list as it was.
    @discardableResult
    func refresh(apiKey: String, force: Bool = false) async -> Bool {
        if !force, let last = defaults.object(forKey: Self.fetchedAtKey) as? Double,
           now().timeIntervalSince1970 - last < Self.refreshInterval {
            return false
        }
        guard let fetched = await fetchAll(apiKey: apiKey), !fetched.isEmpty else { return false }
        models = fetched
        isFromAPI = true
        if let data = try? JSONEncoder().encode(fetched) { defaults.set(data, forKey: Self.cacheKey) }
        defaults.set(now().timeIntervalSince1970, forKey: Self.fetchedAtKey)
        return true
    }

    private func fetchAll(apiKey: String) async -> [ModelInfo]? {
        var all: [ModelInfo] = []
        var afterID: String?
        for _ in 0..<Self.maxPages {
            guard let page = await fetchPage(apiKey: apiKey, afterID: afterID) else { return nil }
            all += page.models
            guard page.hasMore, let last = page.lastID else { break }
            afterID = last
        }
        let claude = all.filter { $0.id.hasPrefix("claude-") }
        return claude.sorted { $0.created > $1.created }
    }

    private struct Page {
        let models: [ModelInfo]
        let hasMore: Bool
        let lastID: String?
    }

    private func fetchPage(apiKey: String, afterID: String?) async -> Page? {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            + (afterID.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return nil }
        return Page(models: items.compactMap(Self.info(from:)),
                    hasMore: object["has_more"] as? Bool ?? false,
                    lastID: object["last_id"] as? String)
    }

    private static func info(from item: [String: Any]) -> ModelInfo? {
        guard let id = item["id"] as? String else { return nil }
        let effort = (item["capabilities"] as? [String: Any])?["effort"] as? [String: Any]
        return ModelInfo(id: id,
                         displayName: (item["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ModelName.short(id),
                         created: (item["created_at"] as? String).flatMap(parseDate) ?? 0,
                         acceptsLowEffort: acceptsLowEffort(effort))
    }

    /// `effort.supported` is the gate; a model that lists levels must list `low` as supported.
    private static func acceptsLowEffort(_ effort: [String: Any]?) -> Bool? {
        guard let supported = effort?["supported"] as? Bool else { return nil }
        guard supported else { return false }
        let low = (effort?["low"] as? [String: Any])?["supported"] as? Bool
        return low ?? true
    }

    private static func parseDate(_ text: String) -> TimeInterval? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (plain.date(from: text) ?? fractional.date(from: text))?.timeIntervalSince1970
    }
}

/// Which models take the server-side fallback beta. Sending it to any other
/// model is an error (older models reject it; Haiku 5.5 has no fallback).
enum ServerSideFallback {
    static let betaHeader = "server-side-fallback-2026-07-01"
    static let models: Set<String> = [
        "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-fable-5-2",
    ]

    static func supports(_ model: String) -> Bool { models.contains(model) }
}

/// Whether to send `effort: low` when the catalog has no capability for the model.
/// Haiku 4.5 and Sonnet 4.5 reject effort; everything else current accepts it.
enum EffortRule {
    static func conservativeDefault(for model: String) -> Bool {
        let rejects = model.hasPrefix("claude-haiku-4-5") || model.hasPrefix("claude-sonnet-4-5")
        return !rejects
    }
}
