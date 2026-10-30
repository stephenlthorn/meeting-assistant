import XCTest

@MainActor
final class AppSettingsTranscriptTests: XCTestCase {
    func testSavingTranscriptsIsOffUntilTheUserTurnsItOn() {
        XCTAssertFalse(makeSettings().saveTranscripts)
    }

    func testTheDefaultFolderIsInApplicationSupportWhereICloudDoesNotReach() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Meeting Assistant/Transcripts", isDirectory: true)

        XCTAssertEqual(makeSettings().transcriptFolder.path, expected.path)
        XCTAssertEqual(AppSettings.defaultTranscriptFolder.path, expected.path)
    }

    func testTheDefaultFolderIsNotInDocumentsOrDesktopWhichICloudCanSync() {
        let path = AppSettings.defaultTranscriptFolder.path

        XCTAssertFalse(path.contains("/Documents"), path)
        XCTAssertFalse(path.contains("/Desktop"), path)
        XCTAssertFalse(path.contains("Mobile Documents"), path)
    }

    func testAFolderTheUserNeverChoseIsNotWrittenDownSoOnlyTheirOwnChoiceIsKept() {
        let defaults = freshDefaults()

        _ = makeSettings(defaults: defaults).transcriptFolder

        XCTAssertNil(defaults.object(forKey: "transcriptFolder"), "saving the default would turn it into a choice")
    }

    func testAFolderChosenWhenTheDefaultWasInDocumentsIsKept() {
        let defaults = freshDefaults()
        defaults.set("/Users/someone/Documents/Meeting Assistant", forKey: "transcriptFolder")

        XCTAssertEqual(makeSettings(defaults: defaults).transcriptFolder.path, "/Users/someone/Documents/Meeting Assistant")
    }

    func testSettingsKnowWhenTheChosenFolderSyncsToICloud() {
        let synced = URL(fileURLWithPath: "/Users/someone/Synced/Calls", isDirectory: true)
        let check = ICloudFolderCheck(home: URL(fileURLWithPath: "/Users/someone"),
                                      exists: { _ in true }, isUbiquitous: { $0.path.hasPrefix("/Users/someone/Synced") })
        let settings = makeSettings(iCloud: check)

        XCTAssertFalse(settings.transcriptFolderSyncsToICloud, "the default folder is local")

        settings.transcriptFolder = synced

        XCTAssertTrue(settings.transcriptFolderSyncsToICloud)

        settings.transcriptFolder = URL(fileURLWithPath: "/Users/someone/Local/Calls", isDirectory: true)

        XCTAssertFalse(settings.transcriptFolderSyncsToICloud)
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

    func testThePrivacyTermsAreAtVersionThreeBecauseSummariesSendTheWholeTranscript() {
        XCTAssertEqual(AppSettings.termsVersion, 3)
    }

    func testAgreementToTheEarlierTermsMustBeGivenAgain() {
        let defaults = freshDefaults()
        defaults.set(2, forKey: "acceptedTermsVersion")

        XCTAssertFalse(makeSettings(defaults: defaults).hasAcceptedTerms)
    }

    func testAgreeingToTheCurrentTermsIsRemembered() {
        let defaults = freshDefaults()
        makeSettings(defaults: defaults).acceptTerms()

        XCTAssertTrue(makeSettings(defaults: defaults).hasAcceptedTerms)
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeSettings(defaults: UserDefaults? = nil, iCloud: ICloudFolderCheck = .onDisk()) -> AppSettings {
        AppSettings(defaults: defaults ?? freshDefaults(), secrets: InMemorySecretStore(), environment: [:],
                    anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"), iCloud: iCloud)
    }
}
