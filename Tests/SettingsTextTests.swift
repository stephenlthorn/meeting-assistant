import XCTest

/// Settings wording that carries a promise, checked apart from the layout like the welcome text.
final class SettingsTextTests: XCTestCase {
    func testChoosingABrowserIsSaidToCaptureAllOfItsTabs() {
        let text = SettingsText.meetingAudioHelp

        XCTAssertTrue(text.contains("browser"), text)
        XCTAssertTrue(text.contains("all of its tabs"), text)
    }

    func testMeetingAudioHelpNoLongerPromisesOtherTabsStayOut() {
        let text = SettingsText.meetingAudioHelp

        XCTAssertFalse(text.contains("other tabs"), "ScreenCaptureKit captures the whole app, so that promise was false: \(text)")
    }

    func testMeetingAudioHelpStillSaysWhatTheChoiceDoes() {
        let text = SettingsText.meetingAudioHelp

        XCTAssertTrue(text.contains("music"), text)
        XCTAssertTrue(text.contains("every app is heard"), text)
        XCTAssertTrue(text.contains("next time you start listening"), text)
    }

    func testTranscriptHelpSaysFilesStayOnThisMacUnlessTheFolderSyncs() {
        let text = SettingsText.transcriptsHelp

        XCTAssertTrue(text.contains("stay on this Mac unless you choose a folder that syncs to iCloud"), text)
        XCTAssertTrue(text.contains("readable only by you"), text)
        XCTAssertFalse(text.contains("The files stay on this Mac."), "that sentence promised more than a chosen folder can keep")
    }

    func testTheICloudWarningSaysTheFilesWillSyncAndHowToAvoidIt() {
        let text = SettingsText.iCloudFolderWarning

        XCTAssertTrue(text.contains("iCloud"), text)
        XCTAssertTrue(text.contains("sync"), text)
        XCTAssertTrue(text.contains("Apple"), "it says where the files go: \(text)")
        XCTAssertTrue(text.contains("Choose a folder that isn't synced"), text)
    }

    func testTheFolderLabelsUsePlainHyphensOnly() {
        for text in [SettingsText.meetingAudioHelp, SettingsText.transcriptsHelp, SettingsText.iCloudFolderWarning] {
            XCTAssertFalse(text.contains("—") || text.contains("–"), text)
        }
    }
}
