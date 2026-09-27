import XCTest
import Carbon.HIToolbox

final class HotKeyManagerTests: XCTestCase {
    func testPressingAHotKeyRunsOnlyThatHotKeysAction() throws {
        let firstFired = expectation(description: "first hotkey action runs")
        let secondFired = expectation(description: "second hotkey action does not run")
        secondFired.isInverted = true

        let first = try HotKeyManager(combo: combo(kVK_F13)) { firstFired.fulfill() }
        let second = try HotKeyManager(combo: combo(kVK_F14)) { secondFired.fulfill() }

        sendHotKeyPressed(id: first.id)

        wait(for: [firstFired, secondFired], timeout: 0.5)
        withExtendedLifetime(second) {}
    }

    func testTheLaterRegisteredHotKeyStillRunsItsOwnAction() throws {
        let firstFired = expectation(description: "first hotkey action does not run")
        firstFired.isInverted = true
        let secondFired = expectation(description: "second hotkey action runs")

        let first = try HotKeyManager(combo: combo(kVK_F13)) { firstFired.fulfill() }
        let second = try HotKeyManager(combo: combo(kVK_F14)) { secondFired.fulfill() }

        sendHotKeyPressed(id: second.id)

        wait(for: [firstFired, secondFired], timeout: 0.5)
        withExtendedLifetime(first) {}
    }

    func testRegisteringACombinationThatIsAlreadyTakenThrows() throws {
        let taken = combo(kVK_F15)
        let original = try HotKeyManager(combo: taken) {}

        XCTAssertThrowsError(try HotKeyManager(combo: taken) {}) { error in
            XCTAssertEqual(error as? HotKeyError, .unavailable(taken))
        }
        withExtendedLifetime(original) {}
    }

    func testAReleasedHotKeyNoLongerRunsItsAction() throws {
        let fired = expectation(description: "released hotkey action does not run")
        fired.isInverted = true

        var manager: HotKeyManager? = try HotKeyManager(combo: combo(kVK_F16)) { fired.fulfill() }
        let id = try XCTUnwrap(manager?.id)
        manager = nil

        sendHotKeyPressed(id: id)

        wait(for: [fired], timeout: 0.3)
    }

    private func combo(_ keyCode: Int) -> HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(cmdKey | optionKey | controlKey), label: "test")
    }

    private func sendHotKeyPressed(id: UInt32) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0,
                    EventAttributes(kEventAttributeNone), &event)
        var hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        SendEventToEventTarget(event, GetEventDispatcherTarget())
        ReleaseEvent(event)
    }
}
