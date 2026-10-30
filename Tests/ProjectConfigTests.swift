import XCTest

/// The app's Info.plist strings, read from project.yml where they are declared.
final class ProjectConfigTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testEveryPermissionTheAppCanPromptForHasAnHonestUsageString() throws {
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription", "NSDocumentsFolderUsageDescription"] {
            let text = try XCTUnwrap(usageString(key, in: project), "\(key) is missing from project.yml")
            XCTAssertGreaterThan(text.count, 40, "\(key) should explain why, not just name the permission")
        }
    }

    func testTheDocumentsStringSaysWhatIsWrittenWhereAndThatItStaysOnTheMacUnlessTheFolderSyncs() throws {
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        let text = try XCTUnwrap(usageString("NSDocumentsFolderUsageDescription", in: project))

        XCTAssertTrue(text.contains("Application Support/Meeting Assistant/Transcripts"), "it names the default folder, which is not in Documents")
        XCTAssertTrue(text.contains("transcript"), "it says what is saved")
        XCTAssertTrue(text.contains("stay on this Mac unless you choose a folder that syncs"), "it does not promise what iCloud can undo")
        XCTAssertFalse(text.contains("—") || text.contains("–"), "plain hyphens only")
    }

    private func usageString(_ key: String, in project: String) -> String? {
        let pattern = "\(key):\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: project, range: NSRange(project.startIndex..., in: project)),
              let range = Range(match.range(at: 1), in: project) else { return nil }
        return String(project[range])
    }
}

/// README and PRIVACY.md make the same promises as the welcome screen and Settings, so they are checked
/// against the app's real default folder rather than a copy of it.
@MainActor
final class DocumentedPromiseTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func doc(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private var defaultFolder: String {
        (AppSettings.defaultTranscriptFolder.path as NSString).abbreviatingWithTildeInPath
    }

    func testTheDefaultFolderIsOneICloudDoesNotSync() {
        XCTAssertEqual(defaultFolder, "~/Library/Application Support/Meeting Assistant/Transcripts")
    }

    func testTheReadmeAndThePrivacyPolicyNameTheFolderTheAppActuallyUses() throws {
        for name in ["README.md", "PRIVACY.md"] {
            let text = try doc(name)

            XCTAssertTrue(text.contains(defaultFolder), "\(name) should name \(defaultFolder)")
            XCTAssertFalse(text.contains("~/Documents/Meeting Assistant"), "\(name) still names the old default")
        }
    }

    func testTheReadmeAndThePrivacyPolicySaySavedFilesStayOnThisMacUnlessTheFolderSyncs() throws {
        for name in ["README.md", "PRIVACY.md"] {
            let text = try doc(name)

            XCTAssertTrue(text.contains("unless you choose a folder that syncs"), name)
        }
    }

    func testTheReadmeExplainsHowToFindTheFolderAndWhatTheFirstLaunchAfterUpdatingChanged() throws {
        let readme = try doc("README.md")

        XCTAssertTrue(readme.contains("Show Transcripts Folder"))
        XCTAssertTrue(readme.contains("never changed the shortcuts"), "the move of the default shortcuts is announced")
        XCTAssertTrue(readme.contains("⌃⌥Space"))
    }

    func testTheReadmeSaysABrowserIsCapturedWholeNotOneTab() throws {
        let readme = try doc("README.md")

        XCTAssertTrue(readme.contains("all of its tabs"))
        XCTAssertFalse(readme.contains("other tabs stay out"), "ScreenCaptureKit captures the whole app, so that promise was false")
    }

    func testThePrivacyPolicySaysWhatTheSampleMeetingSendsAndWhen() throws {
        let policy = try doc("PRIVACY.md")

        XCTAssertTrue(policy.contains("sample meeting"))
        XCTAssertTrue(policy.contains("canned answers"), "before agreeing, the sample answers locally")
        // After agreeing, the sample answers its own scripted questions as they come up
        // (AssistantController.showSampleLine), so the policy must not claim "only when you ask".
        XCTAssertTrue(policy.contains("answers the scripted questions with Claude as they come up"),
                      "after agreeing, the sample answers its scripted questions automatically")
        XCTAssertTrue(policy.contains("or your extra instructions"), "extra instructions never go with the sample")
        XCTAssertFalse(policy.contains("only when you ask for an answer"), "the sample does not wait to be asked")
        XCTAssertFalse(policy.contains("The sample meeting captures nothing."), "that sentence left out what it sends")
    }

    func testNoDocumentUsesAnEmOrEnDash() throws {
        for name in ["README.md", "PRIVACY.md"] {
            let text = try doc(name)

            XCTAssertFalse(text.contains("—") || text.contains("–"), "\(name): plain hyphens only")
        }
    }
}
