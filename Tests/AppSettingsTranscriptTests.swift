import XCTest

@MainActor
final class AppSettingsTranscriptTests: XCTestCase {
    func testSavingTranscriptsIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(makeSettings().saveTranscripts)
    }

    func testTheDefaultFolderIsMeetingAssistantInDocuments() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Meeting Assistant", isDirectory: true)

        XCTAssertEqual(makeSettings().transcriptFolder.path, expected.path)
        XCTAssertEqual(AppSettings.defaultTranscriptFolder.path, expected.path)
    }

    func testTheChoiceToSaveAndTheFolderPersist() {
        let defaults = freshDefaults()
        let first = makeSettings(defaults: defaults)
        first.saveTranscripts = true
        first.transcriptFolder = URL(fileURLWithPath: "/Volumes/Work/Calls", isDirectory: true)

        let second = makeSettings(defaults: defaults)

        XCTAssertTrue(second.saveTranscripts)
        XCTAssertEqual(second.transcriptFolder.path, "/Volumes/Work/Calls")
    }

    func testABlankSavedFolderFallsBackToTheDefault() {
        let defaults = freshDefaults()
        defaults.set("", forKey: "transcriptFolder")

        XCTAssertEqual(makeSettings(defaults: defaults).transcriptFolder.path, AppSettings.defaultTranscriptFolder.path)
    }

    func testWithdrawingTheTermsDoesNotTouchTheUsersFolderChoice() {
        let settings = makeSettings()
        settings.saveTranscripts = true

        settings.withdrawTerms()

        XCTAssertTrue(settings.saveTranscripts)
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeSettings(defaults: UserDefaults? = nil) -> AppSettings {
        AppSettings(defaults: defaults ?? freshDefaults(), secrets: InMemorySecretStore(), environment: [:],
                    anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"))
    }
}
