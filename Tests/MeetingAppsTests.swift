import XCTest

final class MeetingAppsTests: XCTestCase {
    func testTheKnownAppsAreTheCommonMeetingAppsAndBrowsers() {
        let ids = MeetingApps.known.map(\.bundleID)

        XCTAssertEqual(ids, [
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "Cisco-Systems.Spark",
            "com.apple.FaceTime",
            "com.tinyspeck.slackmacgap",
            "com.google.Chrome",
            "com.apple.Safari",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac",
            "org.mozilla.firefox",
        ])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryKnownAppHasAUniqueReadableName() {
        let names = MeetingApps.known.map(\.name)

        XCTAssertEqual(Set(names).count, names.count, "two entries with one label could not be told apart")
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(MeetingApps.name(for: "us.zoom.xos"), "Zoom")
        XCTAssertEqual(MeetingApps.name(for: "Cisco-Systems.Spark"), "Webex")
        XCTAssertEqual(MeetingApps.name(for: "company.thebrowser.Browser"), "Arc")
    }

    func testAnUnknownAppHasNoKnownName() {
        XCTAssertNil(MeetingApps.name(for: "com.example.unknown"))
    }

    func testOnlyRunningMeetingAppsAreOffered() {
        let running: Set<String> = ["us.zoom.xos", "com.google.Chrome", "com.apple.finder", "com.apple.dt.Xcode"]

        let choices = MeetingApps.choices(running: running, saved: nil)

        XCTAssertEqual(choices.map(\.name), ["Zoom", "Google Chrome"])
    }

    func testNothingRunningOffersNothingButAllApps() {
        XCTAssertEqual(MeetingApps.choices(running: [], saved: nil), [])
    }

    func testTheSavedChoiceIsOfferedEvenWhenItIsNotRunning() {
        let choices = MeetingApps.choices(running: ["com.google.Chrome"], saved: "us.zoom.xos")

        XCTAssertEqual(choices.map(\.name), ["Zoom", "Google Chrome"], "in the list's order, not first")
    }

    func testASavedAppThatIsNotOnTheListIsStillOfferedByItsIdentifier() {
        let choices = MeetingApps.choices(running: ["us.zoom.xos"], saved: "com.example.callapp")

        XCTAssertEqual(choices.map(\.bundleID), ["us.zoom.xos", "com.example.callapp"])
        XCTAssertEqual(choices.last?.name, "com.example.callapp")
    }

    func testASavedAppThatIsRunningIsNotListedTwice() {
        let choices = MeetingApps.choices(running: ["us.zoom.xos"], saved: "us.zoom.xos")

        XCTAssertEqual(choices.map(\.bundleID), ["us.zoom.xos"])
    }

    func testAnAppThatIsNotRunningSaysSoInItsLabel() throws {
        let zoom = try XCTUnwrap(MeetingApps.known.first)

        XCTAssertEqual(MeetingApps.label(for: zoom, running: ["us.zoom.xos"]), "Zoom")
        XCTAssertEqual(MeetingApps.label(for: zoom, running: []), "Zoom (not running)")
    }
}
