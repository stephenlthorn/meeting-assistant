import XCTest

@MainActor
final class CaptureTargetSettingsTests: XCTestCase {
    func testByDefaultEveryAppIsHeard() {
        XCTAssertNil(freshSettings().captureAppBundleID)
    }

    func testTheChosenAppPersistsToTheNextLaunch() {
        let defaults = freshDefaults()
        freshSettings(defaults: defaults).captureAppBundleID = "us.zoom.xos"

        XCTAssertEqual(freshSettings(defaults: defaults).captureAppBundleID, "us.zoom.xos")
    }

    func testChoosingAllAppsAgainIsRemembered() {
        let defaults = freshDefaults()
        let first = freshSettings(defaults: defaults)
        first.captureAppBundleID = "us.zoom.xos"

        first.captureAppBundleID = nil

        XCTAssertNil(freshSettings(defaults: defaults).captureAppBundleID)
    }

    func testAnEmptyStoredIdentifierMeansAllApps() {
        let defaults = freshDefaults()
        defaults.set("", forKey: "captureAppBundleID")

        XCTAssertNil(freshSettings(defaults: defaults).captureAppBundleID)
    }

    func testChangingTheAppDoesNotMoveTheSpeechBackend() {
        let settings = freshSettings()
        let before = TranscriberFactory.plan(for: settings, analyzerAvailable: true)

        settings.captureAppBundleID = "us.zoom.xos"

        XCTAssertEqual(TranscriberFactory.plan(for: settings, analyzerAvailable: true), before)
        XCTAssertFalse(settings.sendsAudioToDeepgram)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func freshSettings(defaults: UserDefaults? = nil) -> AppSettings {
        AppSettings(defaults: defaults ?? freshDefaults(), secrets: InMemorySecretStore(), environment: [:],
                    anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"))
    }
}
