import XCTest

/// Check for Updates through the real checker, with the network replaced by a URLProtocol stub.
/// Nothing here can reach GitHub.
final class UpdateCheckerTests: XCTestCase {
    private let release = "https://github.com/stephenlthorn/meeting-assistant"

    override func setUp() {
        UpdateStubURLProtocol.reset()
    }

    override func tearDown() {
        UpdateStubURLProtocol.reset()
    }

    private func check(current: String = "0.4.0", status: Int = 200, body: String, headers: [String: String] = [:]) async -> UpdateCheckResult {
        UpdateStubURLProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(body.utf8))
        }
        return await makeChecker(current: current).check()
    }

    private func makeChecker(current: String) -> UpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        return UpdateChecker(session: URLSession(configuration: configuration), currentVersion: current)
    }

    private func latest(_ tag: String, notes: String = "Fixes.") -> String {
        let escaped = notes.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        return #"{"tag_name":"\#(tag)","name":"\#(tag)","body":"\#(escaped)","html_url":"https://evil.example/\#(tag)","prerelease":false}"#
    }

    // MARK: - Results

    func testANewerReleaseIsAvailableWithItsNotesAndDirectLinks() async {
        let result = await check(current: "0.4.0", body: latest("v0.5.0", notes: "  Faster answers.\r\n\r\n- Fixed a crash.\n  "))

        XCTAssertEqual(result, .available(AvailableUpdate(
            version: "v0.5.0",
            notes: "Faster answers.\n\n- Fixed a crash.",
            downloadURL: URL(string: "\(release)/releases/latest/download/MeetingAssistant.app.zip")!,
            releasePage: URL(string: "\(release)/releases/tag/v0.5.0")!)))
        XCTAssertEqual(result.headline, "v0.5.0 is available")
    }

    func testTheSameVersionIsUpToDate() async {
        let result = await check(current: "0.4.0", body: latest("v0.4.0"))

        XCTAssertEqual(result, .upToDate(version: "v0.4.0"))
        XCTAssertEqual(result.headline, "You're up to date (v0.4.0)")
    }

    func testAnOlderLatestReleaseMeansTheRunningBuildIsAheadSoItIsUpToDate() async {
        let result = await check(current: "0.4.0", body: latest("v0.3.0"))

        XCTAssertEqual(result, .upToDate(version: "v0.4.0"))
    }

    func testVersionsCompareByNumberNotByText() async {
        let newer = await check(current: "0.9.9", body: latest("v0.10.0"))
        let older = await check(current: "0.10.0", body: latest("v0.9.9"))

        guard case .available = newer else { return XCTFail("v0.10.0 is newer than 0.9.9, got \(newer)") }
        XCTAssertEqual(older, .upToDate(version: "v0.10.0"))
        XCTAssertTrue(SemanticVersion("v0.10.0")! > SemanticVersion("v0.9.9")!)
        XCTAssertTrue(SemanticVersion("v1.0.0")! > SemanticVersion("v0.99.99")!)
        XCTAssertTrue(SemanticVersion("v0.4.1")! > SemanticVersion("0.4.0")!, "the leading v is optional")
    }

    func testOnlyThreeNumberVersionsAreAccepted() {
        for bad in ["", "v", "latest", "v1", "v1.2", "v1.2.3.4", "v1.2.3-beta", "v1.2.x", "v1..3", "v-1.2.3", "v1.2.3 ", "v١.٢.٣"] {
            XCTAssertNil(SemanticVersion(bad), "\(bad.debugDescription) is not a version")
        }
        XCTAssertEqual(SemanticVersion("v12.0.345")?.tag, "v12.0.345")
    }

    // MARK: - The request

    func testItAsksForTheLatestReleaseWithoutCredentialsOrAnythingAboutTheUser() async throws {
        _ = await check(body: latest("v0.4.0"))

        let request = try XCTUnwrap(UpdateStubURLProtocol.requests.first)
        XCTAssertEqual(UpdateStubURLProtocol.requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/stephenlthorn/meeting-assistant/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.url?.query, nil)
    }

    func testTheReleasePageLinkIsBuiltFromTheTagNotTakenFromTheReply() async {
        let result = await check(body: latest("v0.5.0"))

        guard case let .available(update) = result else { return XCTFail("expected an update, got \(result)") }
        XCTAssertEqual(update.releasePage.host, "github.com")
        XCTAssertFalse(update.releasePage.absoluteString.contains("evil"))
        XCTAssertEqual(update.downloadURL.host, "github.com")
    }

    func testLongNotesAreCutAtAReadableLength() async {
        let result = await check(body: latest("v0.5.0", notes: String(repeating: "word ", count: 1_000)))

        guard case let .available(update) = result else { return XCTFail("expected an update, got \(result)") }
        XCTAssertLessThanOrEqual(update.notes.count, UpdateChecker.releaseNotesLimit + 3)
        XCTAssertTrue(update.notes.hasSuffix("..."))
    }

    func testAReleaseWithNoNotesStillOffersTheUpdate() async {
        let result = await check(body: #"{"tag_name":"v0.5.0","body":null}"#)

        guard case let .available(update) = result else { return XCTFail("expected an update, got \(result)") }
        XCTAssertEqual(update.notes, "")
    }

    // MARK: - Failures

    func testAMalformedReplyIsAClearErrorNotACrashOrAFalseUpToDate() async {
        for body in ["not json", "<html>Bad gateway</html>", "{}", #"{"tag_name":42}"#, #"{"tag_name":"latest"}"#,
                     #"{"tag_name":"v1.2"}"#, #"{"tag_name":"v1.2.3-beta"}"#, "[]", ""] {
            let result = await check(body: body)

            guard case let .failed(message) = result else { return XCTFail("\(body.debugDescription) gave \(result)") }
            XCTAssertTrue(message.contains("could not read"), message)
        }
    }

    func testARateLimitIsSaidPlainly() async {
        for status in [403, 429] {
            let result = await check(status: status, body: #"{"message":"API rate limit exceeded"}"#, headers: ["x-ratelimit-remaining": "0"])

            guard case let .failed(message) = result else { return XCTFail("\(status) gave \(result)") }
            XCTAssertTrue(message.contains("limiting requests"), message)
            XCTAssertTrue(message.contains("Try again"), message)
        }
    }

    func testOtherHTTPFailuresNameTheStatus() async {
        let missing = await check(status: 404, body: #"{"message":"Not Found"}"#)
        let broken = await check(status: 502, body: "")
        let odd = await check(status: 418, body: "")

        XCTAssertEqual(missing, .failed(message: "GitHub has no published release of Meeting Assistant yet."))
        guard case let .failed(brokenMessage) = broken, case let .failed(oddMessage) = odd else { return XCTFail() }
        XCTAssertTrue(brokenMessage.contains("502"), brokenMessage)
        XCTAssertTrue(oddMessage.contains("418"), oddMessage)
    }

    func testBeingOfflineSaysSoAndToCheckTheConnection() async {
        for code in [URLError.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut] {
            UpdateStubURLProtocol.failure = URLError(code)

            let result = await makeChecker(current: "0.4.0").check()

            guard case let .failed(message) = result else { return XCTFail("\(code) gave \(result)") }
            XCTAssertTrue(message.contains("Can't reach GitHub"), message)
            XCTAssertTrue(message.contains("internet connection"), message)
        }
    }

    func testAnUnreadableRunningVersionFailsWithoutAskingGitHub() async {
        for current in ["", "dev", "1.0"] {
            UpdateStubURLProtocol.reset()

            let result = await makeChecker(current: current).check()

            guard case .failed = result else { return XCTFail("\(current.debugDescription) gave \(result)") }
            XCTAssertTrue(UpdateStubURLProtocol.requests.isEmpty, "no request for \(current.debugDescription)")
        }
    }

    func testTheSessionKeepsNoCookiesOrCache() {
        let configuration = UpdateChecker.makeSession().configuration

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, 30)
    }
}

// MARK: - The shell around it

/// Check for Updates through the real coordinator and menu state: it runs when asked, shows what it found,
/// and never runs on its own.
@MainActor
final class UpdateMenuTests: XCTestCase {
    private func makeCoordinator(checker: FakeUpdateChecker, window: FakeUpdateWindow) -> AppCoordinator {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppSettings.termsVersion, forKey: "acceptedTermsVersion")
        let settings = AppSettings(defaults: defaults, secrets: InMemorySecretStore(values: [:]), environment: [:],
                                   anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"))
        let clock = TestClock()
        let controller = AssistantController(settings: settings, systemAudio: FakeSystemAudio(), microphone: FakeMicrophone(),
                                             makeTranscriber: FakeTranscriberFactory().make, answerer: FakeAnswerer(),
                                             now: { clock.now }, schedule: ManualScheduler().schedule,
                                             sampleWordDelay: 0, transcriptFiles: FakeTranscriptFiles())
        let log = WindowLog()
        return AppCoordinator(settings: settings, controller: controller,
                              hotKeys: HotKeyBinder(register: FakeHotKeyRegistry().register),
                              overlay: FakeOverlay(), welcome: FakeWelcome(log: log), summary: FakeSummaryWindow(log: log),
                              dialogs: FakeDialogs(), clipboard: FakeClipboard(),
                              updates: checker, updateWindow: window)
    }

    func testChoosingCheckForUpdatesShowsTheResult() async {
        let checker = FakeUpdateChecker(result: .upToDate(version: "v0.4.0"))
        let window = FakeUpdateWindow()
        let coordinator = makeCoordinator(checker: checker, window: window)

        await coordinator.checkForUpdates()

        XCTAssertEqual(checker.calls, 1)
        XCTAssertEqual(window.shown, [.upToDate(version: "v0.4.0")])
    }

    func testNothingChecksUntilTheUserAsks() async {
        let checker = FakeUpdateChecker(result: .upToDate(version: "v0.4.0"))
        let window = FakeUpdateWindow()
        let coordinator = makeCoordinator(checker: checker, window: window)

        coordinator.start()
        _ = coordinator.menu
        coordinator.toggleOverlay()
        await settle()

        XCTAssertEqual(checker.calls, 0, "no check at launch, none on a schedule, none from opening the menu")
        XCTAssertTrue(window.shown.isEmpty)
    }

    func testTheMenuItemShowsWhileACheckRunsAndAFurtherClickDoesNothing() async {
        let checker = FakeUpdateChecker(result: .failed(message: "Can't reach GitHub."), holdsUntilReleased: true)
        let window = FakeUpdateWindow()
        let coordinator = makeCoordinator(checker: checker, window: window)
        XCTAssertEqual(coordinator.menu.checkForUpdatesTitle, "Check for Updates…")
        XCTAssertTrue(coordinator.menu.canCheckForUpdates)

        let first = Task { await coordinator.checkForUpdates() }
        await eventually { checker.calls == 1 }
        XCTAssertEqual(coordinator.menu.checkForUpdatesTitle, "Checking for Updates…")
        XCTAssertFalse(coordinator.menu.canCheckForUpdates)
        await coordinator.checkForUpdates()
        XCTAssertEqual(checker.calls, 1, "a second click while checking is ignored")

        checker.release()
        await first.value

        XCTAssertEqual(window.shown, [.failed(message: "Can't reach GitHub.")], "shown once")
        XCTAssertTrue(coordinator.menu.canCheckForUpdates)
        XCTAssertEqual(coordinator.menu.checkForUpdatesTitle, "Check for Updates…")
    }

    func testAnAvailableUpdateReachesTheWindowWithItsLinks() async {
        let update = AvailableUpdate(version: "v0.5.0", notes: "Fixes.",
                                     downloadURL: UpdateChecker.downloadURL,
                                     releasePage: URL(string: "https://github.com/stephenlthorn/meeting-assistant/releases/tag/v0.5.0")!)
        let checker = FakeUpdateChecker(result: .available(update))
        let window = FakeUpdateWindow()
        let coordinator = makeCoordinator(checker: checker, window: window)

        await coordinator.checkForUpdates()
        await coordinator.checkForUpdates()

        XCTAssertEqual(window.shown, [.available(update), .available(update)], "after one finishes, the next click checks again")
    }
}

// MARK: - Fakes

private final class UpdateStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _respond: ((URLRequest) -> (HTTPURLResponse, Data))?
    private static var _failure: URLError?
    private static var _requests: [URLRequest] = []

    static var respond: ((URLRequest) -> (HTTPURLResponse, Data))? {
        get { lock.withLock { _respond } }
        set { lock.withLock { _respond = newValue } }
    }

    static var failure: URLError? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _respond = nil
            _failure = nil
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        guard let respond = Self.respond else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (response, data) = respond(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The checker as the coordinator sees it. It can be held open to look at the menu mid-check.
private final class FakeUpdateChecker: UpdateChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let result: UpdateCheckResult
    private let holds: Bool
    private var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    init(result: UpdateCheckResult, holdsUntilReleased: Bool = false) {
        self.result = result
        holds = holdsUntilReleased
    }

    var calls: Int { lock.withLock { count } }

    func check() async -> UpdateCheckResult {
        lock.withLock { count += 1 }
        if holds {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if released { return true }
                    gate = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        return result
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}

@MainActor
private final class FakeUpdateWindow: UpdatePresenting {
    private(set) var shown: [UpdateCheckResult] = []

    func show(_ result: UpdateCheckResult) { shown.append(result) }
}
