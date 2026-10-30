import XCTest

final class ModelNameTests: XCTestCase {
    func testTheModelsSettingsOffersReadAsTheirShortNames() {
        XCTAssertEqual(ModelName.short("claude-haiku-4-5"), "Haiku 4.5")
        XCTAssertEqual(ModelName.short("claude-sonnet-5"), "Sonnet 5")
        XCTAssertEqual(ModelName.short("claude-opus-5"), "Opus 5")
    }

    func testADatedSnapshotDropsItsDate() {
        XCTAssertEqual(ModelName.short("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
    }

    func testAnIdThatDoesNotFollowThePatternIsShownAsItIs() {
        XCTAssertEqual(ModelName.short("claude-3-5-sonnet-latest"), "claude-3-5-sonnet-latest")
        XCTAssertEqual(ModelName.short("claude-haiku-4-5-latest"), "claude-haiku-4-5-latest")
        XCTAssertEqual(ModelName.short("my-own-model"), "my-own-model")
        XCTAssertEqual(ModelName.short("claude-haiku"), "claude-haiku")
        XCTAssertEqual(ModelName.short(""), "")
    }
}

final class StatusLineTests: XCTestCase {
    func testListeningNamesTheBackendAndTheModel() {
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device)", listening: .listening, model: "claude-haiku-4-5"),
                       "Listening (on-device) - Haiku 4.5")
        XCTAssertEqual(StatusLine.text(status: "Listening (Deepgram)", listening: .listening, model: "claude-sonnet-5"),
                       "Listening (Deepgram) - Sonnet 5")
        XCTAssertEqual(StatusLine.text(status: "Listening (Apple servers)", listening: .listening, model: "claude-opus-5"),
                       "Listening (Apple servers) - Opus 5")
    }

    func testAHalfWorkingSideKeepsItsExplanationBeforeTheModel() {
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device, their side only)", listening: .listening,
                                       model: "claude-haiku-4-5"),
                       "Listening (on-device, their side only) - Haiku 4.5")
    }

    func testOnlyAnActiveCallNamesTheModel() {
        XCTAssertEqual(StatusLine.text(status: "Idle", listening: .idle, model: "claude-haiku-4-5"), "Idle")
        XCTAssertEqual(StatusLine.text(status: "Stopped", listening: .idle, model: "claude-haiku-4-5"), "Stopped")
        XCTAssertEqual(StatusLine.text(status: "Starting…", listening: .starting, model: "claude-haiku-4-5"), "Starting…")
        XCTAssertEqual(StatusLine.text(status: "Sample meeting (nothing is recorded)", listening: .sample,
                                       model: "claude-haiku-4-5"),
                       "Sample meeting (nothing is recorded)")
    }

    func testAModelWithoutAShortNameIsShownByItsId() {
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device)", listening: .listening, model: "my-own-model"),
                       "Listening (on-device) - my-own-model")
    }
}
