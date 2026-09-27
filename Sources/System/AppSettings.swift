import Foundation

/// App-wide, persisted settings: UserDefaults for preferences, a SecretStore
/// (the Keychain) for API keys. `shared` is the app's instance; tests build
/// their own over in-memory storage.
@MainActor
final class AppSettings: ObservableObject {
    enum KeySource: Equatable {
        case keychain, environment, file
    }

    /// Bump when the privacy terms shown on the welcome screen change, so
    /// everyone is asked to agree again.
    static let termsVersion = 1
    static let bundleID = "com.stephenthorn.meetingassistant"
    static let legacyBundleID = "com.example.meetingassistant"

    static let shared: AppSettings = {
        let defaults = UserDefaults.standard
        let secrets = KeychainStore(service: bundleID)
        if let legacyDefaults = UserDefaults(suiteName: legacyBundleID) {
            migrateLegacySettings(from: legacyDefaults, legacySecrets: KeychainStore(service: legacyBundleID),
                                  to: defaults, secrets: secrets)
        }
        let keyFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/meeting-assistant/anthropic_key")
        return AppSettings(defaults: defaults, secrets: secrets,
                           environment: ProcessInfo.processInfo.environment, anthropicKeyFile: keyFile)
    }()

    private static let anthropicAccount = "anthropic_api_key"
    private static let deepgramAccount = "deepgram_api_key"
    private static let preferenceKeys = ["model", "profile", "extraInstructions", "autoAnswer", "useCloudSTT"]

    let availableModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]

    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var profile: Profile { didSet { defaults.set(profile.rawValue, forKey: "profile") } }
    @Published var extraInstructions: String { didSet { defaults.set(extraInstructions, forKey: "extraInstructions") } }
    @Published var autoAnswer: Bool { didSet { defaults.set(autoAnswer, forKey: "autoAnswer") } }
    @Published var useCloudSTT: Bool { didSet { defaults.set(useCloudSTT, forKey: "useCloudSTT") } }
    @Published var answerHotKey: HotKeyCombo { didSet { defaults.set(answerHotKey.label, forKey: "answerHotKey") } }
    @Published var overlayHotKey: HotKeyCombo { didSet { defaults.set(overlayHotKey.label, forKey: "overlayHotKey") } }
    @Published var showsOverlay: Bool { didSet { defaults.set(showsOverlay, forKey: "showsOverlay") } }
    @Published private(set) var acceptedTermsVersion: Int {
        didSet { defaults.set(acceptedTermsVersion, forKey: "acceptedTermsVersion") }
    }
    @Published private(set) var cloudAudioAccepted: Bool {
        didSet { defaults.set(cloudAudioAccepted, forKey: "cloudAudioAccepted") }
    }
    @Published private(set) var apiKeySource: KeySource?
    @Published private(set) var deepgramKeySource: KeySource?

    var apiKeyPresent: Bool { apiKeySource != nil }
    var hasAcceptedTerms: Bool { acceptedTermsVersion >= Self.termsVersion }

    private let defaults: UserDefaults
    private let secrets: SecretStore
    private let environment: [String: String]
    private let anthropicKeyFile: URL

    init(defaults: UserDefaults, secrets: SecretStore, environment: [String: String], anthropicKeyFile: URL) {
        self.defaults = defaults
        self.secrets = secrets
        self.environment = environment
        self.anthropicKeyFile = anthropicKeyFile
        model = defaults.string(forKey: "model") ?? "claude-haiku-4-5"
        profile = defaults.string(forKey: "profile").flatMap(Profile.init(rawValue:)) ?? .general
        extraInstructions = defaults.string(forKey: "extraInstructions") ?? ""
        autoAnswer = defaults.bool(forKey: "autoAnswer")
        useCloudSTT = defaults.bool(forKey: "useCloudSTT")
        answerHotKey = HotKeyCombo.choice(labeled: defaults.string(forKey: "answerHotKey"), in: HotKeyCombo.answerChoices)
        overlayHotKey = HotKeyCombo.choice(labeled: defaults.string(forKey: "overlayHotKey"),
                                           in: HotKeyCombo.overlayChoices)
        showsOverlay = defaults.object(forKey: "showsOverlay") as? Bool ?? true
        acceptedTermsVersion = defaults.integer(forKey: "acceptedTermsVersion")
        cloudAudioAccepted = defaults.bool(forKey: "cloudAudioAccepted")
        refreshKeySources()
    }

    /// The selected profile's prompt plus the user's extra instructions.
    var systemPrompt: String {
        let extra = extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return profile.systemPrompt }
        return profile.systemPrompt + "\n\nAdditional instructions from the user:\n" + extra
    }

    // MARK: - Consent

    func acceptTerms() {
        acceptedTermsVersion = Self.termsVersion
    }

    /// Withdrawing the terms also stops any audio going to Deepgram.
    func withdrawTerms() {
        acceptedTermsVersion = 0
        cloudAudioAccepted = false
        useCloudSTT = false
    }

    /// The user agreed to stream call audio to Deepgram; turns cloud STT on.
    func acceptCloudAudio() {
        cloudAudioAccepted = true
        useCloudSTT = true
    }

    // MARK: - Keys

    @discardableResult
    func setAPIKey(_ key: String) -> Bool { save(key, account: Self.anthropicAccount) }

    func removeAPIKey() {
        secrets.delete(Self.anthropicAccount)
        refreshKeySources()
    }

    @discardableResult
    func setDeepgramKey(_ key: String) -> Bool { save(key, account: Self.deepgramAccount) }

    func removeDeepgramKey() {
        secrets.delete(Self.deepgramAccount)
        refreshKeySources()
    }

    /// Anthropic key: Keychain, then `ANTHROPIC_API_KEY`, then the key file.
    func resolveAPIKey() -> String? {
        resolve(account: Self.anthropicAccount, environmentKey: "ANTHROPIC_API_KEY", file: anthropicKeyFile)
    }

    /// Deepgram key: Keychain, then `DEEPGRAM_API_KEY`.
    func resolveDeepgramKey() -> String? {
        resolve(account: Self.deepgramAccount, environmentKey: "DEEPGRAM_API_KEY", file: nil)
    }

    // MARK: - Migration

    /// Copies preferences and keys saved under the old `com.example` bundle id,
    /// never overwriting anything already saved under the new one.
    static func migrateLegacySettings(from legacyDefaults: UserDefaults, legacySecrets: SecretStore,
                                      to defaults: UserDefaults, secrets: SecretStore) {
        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            if let value = legacyDefaults.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        for account in [anthropicAccount, deepgramAccount]
        where !secrets.contains(account) && legacySecrets.contains(account) {
            if let value = legacySecrets.read(account), secrets.write(value, for: account) {
                legacySecrets.delete(account)
            }
        }
    }

    // MARK: - Private

    private func save(_ key: String, account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = secrets.write(trimmed, for: account)
        refreshKeySources()
        return saved
    }

    private func refreshKeySources() {
        apiKeySource = source(account: Self.anthropicAccount, environmentKey: "ANTHROPIC_API_KEY",
                              file: anthropicKeyFile)
        deepgramKeySource = source(account: Self.deepgramAccount, environmentKey: "DEEPGRAM_API_KEY", file: nil)
    }

    private func source(account: String, environmentKey: String, file: URL?) -> KeySource? {
        if secrets.contains(account) { return .keychain }
        if nonEmpty(environment[environmentKey]) != nil { return .environment }
        if fileKey(file) != nil { return .file }
        return nil
    }

    private func resolve(account: String, environmentKey: String, file: URL?) -> String? {
        if secrets.contains(account), let stored = nonEmpty(secrets.read(account)) { return stored }
        return nonEmpty(environment[environmentKey]) ?? fileKey(file)
    }

    private func fileKey(_ file: URL?) -> String? {
        nonEmpty(file.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
