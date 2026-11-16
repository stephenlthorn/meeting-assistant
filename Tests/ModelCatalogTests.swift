import XCTest

/// Q1: the model list comes from the Models API, is cached, and falls back to a built-in list.
@MainActor
final class ModelCatalogTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.respond = nil
        super.tearDown()
    }

    // MARK: - Fetching

    func testEveryPageOfTheModelsListIsFollowed() async throws {
        let log = RequestLog()
        StubURLProtocol.respond = { request in
            log.add(request)
            let afterID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "after_id" })?.value
            switch afterID {
            case nil:
                return Self.page([Self.item("claude-sonnet-5-5", created: "2026-07-01T00:00:00Z")],
                                 hasMore: true, lastID: "claude-sonnet-5-5", for: request)
            default:
                return Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z")],
                                 hasMore: false, lastID: "claude-haiku-5-5", for: request)
            }
        }
        let catalog = makeCatalog()

        let updated = await catalog.refresh(apiKey: "sk-test")

        XCTAssertTrue(updated)
        XCTAssertEqual(catalog.models.map(\.id), ["claude-haiku-5-5", "claude-sonnet-5-5"])
        let requests = log.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertTrue(requests.first?.url?.absoluteString.hasPrefix("https://api.anthropic.com/v1/models") ?? false)
        XCTAssertTrue(requests.first?.url?.query?.contains("limit=1000") ?? false)
    }

    func testIdsThatAreNotClaudeModelsAreDropped() async {
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-opus-5-5", created: "2026-07-01T00:00:00Z"),
                       Self.item("gpt-9", created: "2026-09-01T00:00:00Z"),
                       Self.item("text-embedding-x", created: "2026-09-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let catalog = makeCatalog()

        await catalog.refresh(apiKey: "sk-test")

        XCTAssertEqual(catalog.models.map(\.id), ["claude-opus-5-5"])
    }

    func testTheNewestModelComesFirstAndDisplayNamesAreKept() async {
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-old", name: "Old One", created: "2025-01-01T00:00:00Z"),
                       Self.item("claude-new", name: "New One", created: "2026-09-01T12:30:00.123Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let catalog = makeCatalog()

        await catalog.refresh(apiKey: "sk-test")

        XCTAssertEqual(catalog.models.map(\.id), ["claude-new", "claude-old"])
        XCTAssertEqual(catalog.displayName(for: "claude-new"), "New One")
        XCTAssertNil(catalog.displayName(for: "claude-unknown"))
    }

    func testEffortSupportIsReadFromTheCapabilities() async {
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-sonnet-5-5", created: "2026-07-01T00:00:00Z", effort: true),
                       Self.item("claude-haiku-4-5", created: "2025-10-01T00:00:00Z", effort: false)],
                      hasMore: false, lastID: "x", for: request)
        }
        let catalog = makeCatalog()

        await catalog.refresh(apiKey: "sk-test")

        XCTAssertEqual(catalog.supportsEffort("claude-sonnet-5-5"), true)
        XCTAssertEqual(catalog.supportsEffort("claude-haiku-4-5"), false)
        XCTAssertNil(catalog.supportsEffort("claude-never-heard-of-it"))
    }

    // MARK: - Offline and fallback

    func testTheCachedListIsUsedWhenTheNetworkIsDown() async {
        let defaults = freshDefaults()
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-fable-5-2", name: "Fable 5.2", created: "2026-09-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        await makeCatalog(defaults: defaults).refresh(apiKey: "sk-test")
        StubURLProtocol.respond = nil

        let offline = makeCatalog(defaults: defaults)
        let updated = await offline.refresh(apiKey: "sk-test", force: true)

        XCTAssertFalse(updated)
        XCTAssertEqual(offline.models.map(\.id), ["claude-fable-5-2"])
        XCTAssertTrue(offline.isFromAPI)
    }

    func testAFailedFetchKeepsTheListAlreadyShown() async {
        StubURLProtocol.respond = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let catalog = makeCatalog()

        let updated = await catalog.refresh(apiKey: "sk-test")

        XCTAssertFalse(updated)
        XCTAssertEqual(catalog.models.map(\.id), ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertFalse(catalog.isFromAPI)
    }

    func testWithNothingCachedTheBuiltInListIsUsed() {
        let catalog = makeCatalog()

        XCTAssertEqual(catalog.models.map(\.id), ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertFalse(catalog.isFromAPI)
        XCTAssertEqual(catalog.supportsEffort("claude-haiku-5-5"), true)
    }

    // MARK: - Throttle

    func testTheListIsFetchedAtMostOnceAnHourUnlessForced() async {
        let clock = Clock()
        let log = RequestLog()
        StubURLProtocol.respond = { request in
            log.add(request)
            return Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z")],
                             hasMore: false, lastID: "x", for: request)
        }
        let catalog = makeCatalog(clock: clock)

        await catalog.refresh(apiKey: "sk-test")
        clock.advance(by: 59 * 60)
        let tooSoon = await catalog.refresh(apiKey: "sk-test")
        XCTAssertFalse(tooSoon)
        XCTAssertEqual(log.requests.count, 1)

        clock.advance(by: 2 * 60)
        await catalog.refresh(apiKey: "sk-test")
        XCTAssertEqual(log.requests.count, 2)

        await catalog.refresh(apiKey: "sk-test", force: true)
        XCTAssertEqual(log.requests.count, 3)
    }

    func testTheThrottleSurvivesARelaunch() async {
        let defaults = freshDefaults()
        let clock = Clock()
        let log = RequestLog()
        StubURLProtocol.respond = { request in
            log.add(request)
            return Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z")],
                             hasMore: false, lastID: "x", for: request)
        }
        await makeCatalog(defaults: defaults, clock: clock).refresh(apiKey: "sk-test")

        await makeCatalog(defaults: defaults, clock: clock).refresh(apiKey: "sk-test")

        XCTAssertEqual(log.requests.count, 1)
    }

    // MARK: - Settings

    func testAFreshInstallDefaultsToHaiku55() {
        let settings = makeSettings()

        XCTAssertEqual(settings.model, "claude-haiku-5-5")
    }

    func testAnExistingUsersSavedModelIsKept() {
        let defaults = freshDefaults()
        defaults.set("claude-haiku-4-5", forKey: "model")

        XCTAssertEqual(makeSettings(defaults: defaults).model, "claude-haiku-4-5")
    }

    func testASavedModelThatIsMissingFromTheBuiltInListStillAppearsInThePicker() {
        let defaults = freshDefaults()
        defaults.set("claude-haiku-4-5", forKey: "model")

        let options = makeSettings(defaults: defaults).modelOptions

        XCTAssertTrue(options.map(\.id).contains("claude-haiku-4-5"))
        XCTAssertEqual(options.first(where: { $0.id == "claude-haiku-4-5" })?.name, "Haiku 4.5")
    }

    func testThePickerShowsDisplayNames() async {
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-haiku-5-5", name: "Claude Haiku 5.5", created: "2026-08-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings()

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.modelOptions.map(\.name), ["Claude Haiku 5.5"])
        XCTAssertEqual(settings.modelDisplayName, "Claude Haiku 5.5")
    }

    func testAFetchedListThatDropsTheSavedModelSaysSoAndUsesTheDefault() async {
        let defaults = freshDefaults()
        defaults.set("claude-retired-1", forKey: "model")
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-haiku-5-5", name: "Claude Haiku 5.5", created: "2026-08-01T00:00:00Z"),
                       Self.item("claude-opus-5-5", created: "2026-07-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(defaults: defaults)

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.model, "claude-haiku-5-5")
        XCTAssertTrue(settings.modelNotice?.contains("claude-retired-1") ?? false, settings.modelNotice ?? "nil")
        XCTAssertTrue(settings.modelNotice?.contains("Claude Haiku 5.5") ?? false, settings.modelNotice ?? "nil")
    }

    func testTheBuiltInListNeverOverridesASavedModel() async {
        let defaults = freshDefaults()
        defaults.set("claude-haiku-4-5", forKey: "model")
        StubURLProtocol.respond = nil
        let settings = makeSettings(defaults: defaults)

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.model, "claude-haiku-4-5")
        XCTAssertNil(settings.modelNotice)
    }

    func testWithoutAKeyNothingIsFetched() async {
        let log = RequestLog()
        StubURLProtocol.respond = { request in
            log.add(request)
            return Self.page([], hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(secrets: InMemorySecretStore())

        await settings.refreshModels(force: true)

        XCTAssertTrue(log.requests.isEmpty)
    }

    // MARK: - Dated ids (F3)

    func testASavedAliasIsKeptWhenTheCatalogListsItsDatedId() async {
        let defaults = freshDefaults()
        defaults.set("claude-haiku-4-5", forKey: "model")
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z"),
                       Self.item("claude-haiku-4-5-20251001", name: "Claude Haiku 4.5",
                                 created: "2025-10-01T00:00:00Z", effort: false)],
                      hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(defaults: defaults)

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.model, "claude-haiku-4-5")
        XCTAssertNil(settings.modelNotice)
        XCTAssertEqual(settings.modelDisplayName, "Claude Haiku 4.5")
        XCTAssertEqual(settings.modelSupportsEffort, false)
    }

    func testThePickerShowsOneRowPerModelWhenTheSavedAliasIsTheListedDatedId() async {
        let defaults = freshDefaults()
        defaults.set("claude-haiku-4-5", forKey: "model")
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-haiku-5-5", name: "Claude Haiku 5.5", created: "2026-08-01T00:00:00Z"),
                       Self.item("claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", created: "2025-10-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(defaults: defaults)

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.modelOptions.map(\.id), ["claude-haiku-5-5", "claude-haiku-4-5"])
        XCTAssertEqual(settings.modelOptions.map(\.name), ["Claude Haiku 5.5", "Claude Haiku 4.5"])
    }

    func testAModelThatIsInNeitherFormIsStillReplacedWithTheNotice() async {
        let defaults = freshDefaults()
        defaults.set("claude-sonnet-4-5", forKey: "model")
        StubURLProtocol.respond = { request in
            Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z"),
                       Self.item("claude-haiku-4-5-20251001", created: "2025-10-01T00:00:00Z")],
                      hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(defaults: defaults)

        await settings.refreshModels(force: true)

        XCTAssertEqual(settings.model, "claude-haiku-5-5")
        XCTAssertTrue(settings.modelNotice?.contains("claude-sonnet-4-5") ?? false, settings.modelNotice ?? "nil")
    }

    func testTheFallbackSetMatchesDatedIdsOfItsModels() {
        XCTAssertTrue(ServerSideFallback.supports("claude-sonnet-5-5-20261101"))
        XCTAssertTrue(ServerSideFallback.supports("claude-opus-5-5"))
        XCTAssertFalse(ServerSideFallback.supports("claude-haiku-5-5-20261101"))
        XCTAssertFalse(ServerSideFallback.supports("claude-haiku-4-5"))
    }

    // MARK: - Terms gate (F2)

    func testNoModelListIsFetchedBeforeTheTermsAreAccepted() async {
        let log = RequestLog()
        let secrets = InMemorySecretStore(values: ["anthropic_api_key": "sk-test"])
        StubURLProtocol.respond = { request in
            log.add(request)
            return Self.page([Self.item("claude-haiku-5-5", created: "2026-08-01T00:00:00Z")],
                             hasMore: false, lastID: "x", for: request)
        }
        let settings = makeSettings(secrets: secrets, acceptTerms: false)

        await settings.refreshModels(force: true)

        XCTAssertTrue(log.requests.isEmpty, "the key must not leave the Mac before the terms are accepted")
        XCTAssertEqual(secrets.reads, 0, "and the Keychain is not read for it")

        settings.acceptTerms()
        await settings.refreshModels(force: true)

        XCTAssertEqual(log.requests.count, 1)
    }

    func testTheWelcomeScreenSaysTheModelListUsesTheKey() {
        let text = WelcomeText.whereYourDataGoes

        XCTAssertTrue(text.contains("list of available models"), text)
        XCTAssertTrue(text.contains("only your key"), text)
    }

    func testTheStatusLinePrefersTheCatalogDisplayName() {
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device)", listening: .listening,
                                       model: "claude-haiku-5-5", displayName: "Haiku 5.5 Preview"),
                       "Listening (on-device) - Haiku 5.5 Preview")
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device)", listening: .listening,
                                       model: "claude-haiku-5-5", displayName: "Claude Haiku 5.5"),
                       "Listening (on-device) - Haiku 5.5")
        XCTAssertEqual(StatusLine.text(status: "Listening (on-device)", listening: .listening,
                                       model: "claude-haiku-5-5", displayName: nil),
                       "Listening (on-device) - Haiku 5.5")
    }

    func testNewModelIdsReadAsTheirShortNames() {
        XCTAssertEqual(ModelName.short("claude-haiku-5-5"), "Haiku 5.5")
        XCTAssertEqual(ModelName.short("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(ModelName.short("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.short("claude-fable-5-2"), "Fable 5.2")
    }

    // MARK: - Helpers

    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [URLRequest] = []
        func add(_ request: URLRequest) { lock.withLock { seen.append(request) } }
        var requests: [URLRequest] { lock.withLock { seen } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }

    nonisolated private static func item(_ id: String, name: String? = nil, created: String,
                                         effort: Bool = true) -> [String: Any] {
        ["type": "model", "id": id, "display_name": name ?? id, "created_at": created,
         "max_input_tokens": 200_000, "max_tokens": 64_000,
         "capabilities": ["effort": ["supported": effort, "low": ["supported": effort]]]]
    }

    nonisolated private static func page(_ items: [[String: Any]], hasMore: Bool, lastID: String,
                                         for request: URLRequest) -> (HTTPURLResponse, Data) {
        let body: [String: Any] = ["data": items, "has_more": hasMore, "first_id": "a", "last_id": lastID]
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "MeetingAssistantTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeCatalog(defaults: UserDefaults? = nil, clock: Clock = Clock()) -> ModelCatalog {
        ModelCatalog(defaults: defaults ?? freshDefaults(), session: stubSession(), now: { clock.now })
    }

    private func makeSettings(defaults: UserDefaults? = nil,
                              secrets: SecretStore = InMemorySecretStore(values: ["anthropic_api_key": "sk-test"]),
                              acceptTerms: Bool = true) -> AppSettings {
        let defaults = defaults ?? freshDefaults()
        let settings = AppSettings(defaults: defaults, secrets: secrets, environment: [:],
                                   anthropicKeyFile: URL(fileURLWithPath: "/nonexistent/anthropic_key"),
                                   modelCatalog: makeCatalog(defaults: defaults))
        if acceptTerms { settings.acceptTerms() }
        return settings
    }
}
