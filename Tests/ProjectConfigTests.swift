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

    func testTheDocumentsStringSaysWhatIsWrittenWhereAndThatItStaysOnTheMac() throws {
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)

        let text = try XCTUnwrap(usageString("NSDocumentsFolderUsageDescription", in: project))

        XCTAssertTrue(text.contains("Documents/Meeting Assistant"), "it names the default folder")
        XCTAssertTrue(text.contains("transcript"), "it says what is saved")
        XCTAssertTrue(text.contains("stay on this Mac"), "it says nothing is sent anywhere")
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
