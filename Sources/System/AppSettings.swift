import Foundation

/// App-wide, persisted settings. UserDefaults for preferences, Keychain for the
/// API keys. A shared singleton so views and the controller read one source.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private let apiKeyAccount = "anthropic_api_key"
    private let deepgramAccount = "deepgram_api_key"

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var profileRaw: String { didSet { defaults.set(profileRaw, forKey: "profile") } }
    @Published var extraInstructions: String { didSet { defaults.set(extraInstructions, forKey: "extraInstructions") } }
    @Published var autoAnswer: Bool { didSet { defaults.set(autoAnswer, forKey: "autoAnswer") } }
    @Published var useCloudSTT: Bool { didSet { defaults.set(useCloudSTT, forKey: "useCloudSTT") } }
    @Published var apiKeyPresent: Bool
    @Published var deepgramKeyPresent: Bool

    var profile: Profile { Profile(rawValue: profileRaw) ?? .general }
    let availableModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]

    private init() {
        model = defaults.string(forKey: "model") ?? "claude-haiku-4-5"
        profileRaw = defaults.string(forKey: "profile") ?? Profile.general.rawValue
        extraInstructions = defaults.string(forKey: "extraInstructions") ?? ""
        autoAnswer = defaults.bool(forKey: "autoAnswer")
        useCloudSTT = defaults.bool(forKey: "useCloudSTT")
        apiKeyPresent = KeychainStore.get(apiKeyAccount) != nil
        deepgramKeyPresent = KeychainStore.get(deepgramAccount) != nil
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainStore.delete(apiKeyAccount) } else { KeychainStore.set(trimmed, for: apiKeyAccount) }
        apiKeyPresent = !trimmed.isEmpty
    }

    func setDeepgramKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { KeychainStore.delete(deepgramAccount) } else { KeychainStore.set(trimmed, for: deepgramAccount) }
        deepgramKeyPresent = !trimmed.isEmpty
    }

    /// Anthropic key: Keychain, then env var, then legacy file.
    func resolveAPIKey() -> String? {
        if let stored = KeychainStore.get(apiKeyAccount), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let path = ("~/.config/meeting-assistant/anthropic_key" as NSString).expandingTildeInPath
        if let file = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Deepgram key: Keychain, then env var.
    func resolveDeepgramKey() -> String? {
        if let stored = KeychainStore.get(deepgramAccount), !stored.isEmpty { return stored }
        if let env = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !env.isEmpty { return env }
        return nil
    }
}
