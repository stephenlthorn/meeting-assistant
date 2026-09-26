import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testNothingSavedMeansFastModelGeneralProfileAndManualAnswers() {
        let settings = makeSettings()

        XCTAssertEqual(settings.model, "claude-haiku-4-5")
        XCTAssertEqual(settings.profile, .general)
        XCTAssertFalse(settings.autoAnswer)
        XCTAssertFalse(settings.useCloudSTT)
    }

    func testPreferencesPersistToTheNextLaunch() {
        let defaults = freshDefaults()
        let first = makeSettings(defaults: defaults)
        first.model = "claude-sonnet-5"
        first.profile = .sales
        first.extraInstructions = "Mention SOC 2."
        first.autoAnswer = true
        first.useCloudSTT = true

        let second = makeSettings(defaults: defaults)

        XCTAssertEqual(second.model, "claude-sonnet-5")
        XCTAssertEqual(second.profile, .sales)
        XCTAssertEqual(second.extraInstructions, "Mention SOC 2.")
        XCTAssertTrue(second.autoAnswer)
        XCTAssertTrue(second.useCloudSTT)
    }

    func testTheSystemPromptAppendsExtraInstructionsToTheProfile() {
        let settings = makeSettings()
        settings.profile = .sales
        settings.extraInstructions = "  Mention SOC 2.\n"

        XCTAssertEqual(settings.systemPrompt,
                       Profile.sales.systemPrompt + "\n\nAdditional instructions from the user:\nMention SOC 2.")
    }

    func testBlankExtraInstructionsLeaveTheProfilePromptAlone() {
        let settings = makeSettings()
        settings.extraInstructions = "   "

        XCTAssertEqual(settings.systemPrompt, Profile.general.systemPrompt)
    }

    // MARK: - Anthropic key

    func testASavedKeyIsTrimmedStoredAndUsed() {
        let secrets = InMemorySecretStore()
        let settings = makeSettings(secrets: secrets)

        XCTAssertTrue(settings.setAPIKey("  sk-ant-123 \n"))

        XCTAssertEqual(secrets.values["anthropic_api_key"], "sk-ant-123")
        XCTAssertEqual(settings.resolveAPIKey(), "sk-ant-123")
        XCTAssertEqual(settings.apiKeySource, .keychain)
    }

    func testAKeyFromTheEnvironmentCountsAsSet() {
        let settings = makeSettings(environment: ["ANTHROPIC_API_KEY": "sk-env"])

        XCTAssertEqual(settings.apiKeySource, .environment)
        XCTAssertEqual(settings.resolveAPIKey(), "sk-env")
    }

    func testAKeyFileCountsAsSet() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "sk-file\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let settings = makeSettings(keyFile: file)

        XCTAssertEqual(settings.apiKeySource, .file)
        XCTAssertEqual(settings.resolveAPIKey(), "sk-file")
    }

    func testTheKeychainKeyWinsOverOtherSources() {
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-keychain"])
        let settings = makeSettings(secrets: secrets, environment: ["ANTHROPIC_API_KEY": "sk-env"])

        XCTAssertEqual(settings.apiKeySource, .keychain)
        XCTAssertEqual(settings.resolveAPIKey(), "sk-keychain")
    }

    func testNoKeyAnywhereMeansNoKey() {
        let settings = makeSettings()

        XCTAssertNil(settings.apiKeySource)
        XCTAssertNil(settings.resolveAPIKey())
    }

    func testCheckingForAKeyAtLaunchDoesNotReadTheSecret() {
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-keychain", "deepgram_api_key": "dg"])

        let settings = makeSettings(secrets: secrets)

        XCTAssertEqual(settings.apiKeySource, .keychain)
        XCTAssertEqual(secrets.reads, 0)
    }

    func testAFailedKeychainWriteReportsFailureAndKeepsTheOldKey() {
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-old"])
        let settings = makeSettings(secrets: secrets)
        secrets.failWrites = true

        XCTAssertFalse(settings.setAPIKey("sk-new"))

        XCTAssertEqual(settings.resolveAPIKey(), "sk-old")
        XCTAssertEqual(settings.apiKeySource, .keychain)
    }

    func testRemovingTheSavedKeyFallsBackToTheEnvironment() {
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-keychain"])
        let settings = makeSettings(secrets: secrets, environment: ["ANTHROPIC_API_KEY": "sk-env"])

        settings.removeAPIKey()

        XCTAssertNil(secrets.values["anthropic_api_key"])
        XCTAssertEqual(settings.apiKeySource, .environment)
    }

    // MARK: - Deepgram key

    func testTheDeepgramKeyComesFromTheKeychainOrEnvironment() {
        let fromEnvironment = makeSettings(environment: ["DEEPGRAM_API_KEY": "dg-env"])
        XCTAssertEqual(fromEnvironment.deepgramKeySource, .environment)
        XCTAssertEqual(fromEnvironment.resolveDeepgramKey(), "dg-env")

        let secrets = InMemorySecretStore()
        let saved = makeSettings(secrets: secrets)
        XCTAssertTrue(saved.setDeepgramKey(" dg-1 "))
        XCTAssertEqual(saved.deepgramKeySource, .keychain)
        XCTAssertEqual(saved.resolveDeepgramKey(), "dg-1")

        saved.removeDeepgramKey()
        XCTAssertNil(saved.deepgramKeySource)
    }

    // MARK: - Migration from the com.example bundle id

    func testSettingsAndKeysMoveOverFromTheOldBundleID() {
        let legacyDefaults = freshDefaults()
        legacyDefaults.set("claude-sonnet-5", forKey: "model")
        legacyDefaults.set("Support", forKey: "profile")
        legacyDefaults.set(true, forKey: "autoAnswer")
        let legacySecrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-legacy"])
        let defaults = freshDefaults()
        let secrets = InMemorySecretStore()

        AppSettings.migrateLegacySettings(from: legacyDefaults, legacySecrets: legacySecrets,
                                          to: defaults, secrets: secrets)
        let settings = makeSettings(defaults: defaults, secrets: secrets)

        XCTAssertEqual(settings.model, "claude-sonnet-5")
        XCTAssertEqual(settings.profile, .support)
        XCTAssertTrue(settings.autoAnswer)
        XCTAssertEqual(settings.resolveAPIKey(), "sk-legacy")
        XCTAssertNil(legacySecrets.values["anthropic_api_key"])
    }

    func testMigrationNeverOverwritesNewerSettings() {
        let legacyDefaults = freshDefaults()
        legacyDefaults.set("claude-sonnet-5", forKey: "model")
        let legacySecrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-legacy"])
        let defaults = freshDefaults()
        defaults.set("claude-opus-5", forKey: "model")
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-current"])

        AppSettings.migrateLegacySettings(from: legacyDefaults, legacySecrets: legacySecrets,
                                          to: defaults, secrets: secrets)

        XCTAssertEqual(defaults.string(forKey: "model"), "claude-opus-5")
        XCTAssertEqual(secrets.values["anthropic_api_key"], "sk-current")
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let name = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeSettings(defaults: UserDefaults? = nil,
                              secrets: SecretStore = InMemorySecretStore(),
                              environment: [String: String] = [:],
                              keyFile: URL = URL(fileURLWithPath: "/nonexistent/anthropic_key")) -> AppSettings {
        AppSettings(defaults: defaults ?? freshDefaults(), secrets: secrets,
                    environment: environment, anthropicKeyFile: keyFile)
    }
}
