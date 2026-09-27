import XCTest

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.stephenthorn.meetingassistant.tests.\(UUID().uuidString)")
        guard store.write("probe", for: "probe") else {
            throw XCTSkip("No writable keychain in this environment")
        }
        store.delete("probe")
    }

    override func tearDown() {
        store.delete("account")
        super.tearDown()
    }

    func testAWrittenSecretReadsBack() {
        XCTAssertTrue(store.write("secret-1", for: "account"))

        XCTAssertEqual(store.read("account"), "secret-1")
        XCTAssertTrue(store.contains("account"))
    }

    func testWritingAgainReplacesTheSecret() {
        XCTAssertTrue(store.write("secret-1", for: "account"))
        XCTAssertTrue(store.write("secret-2", for: "account"))

        XCTAssertEqual(store.read("account"), "secret-2")
    }

    func testADeletedSecretIsGone() {
        XCTAssertTrue(store.write("secret-1", for: "account"))

        store.delete("account")

        XCTAssertNil(store.read("account"))
        XCTAssertFalse(store.contains("account"))
    }
}
