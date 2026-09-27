import XCTest

@MainActor
final class HotKeyBinderTests: XCTestCase {
    func testBindingRegistersBothShortcuts() {
        let registry = FakeHotKeyRegistry()
        let binder = HotKeyBinder(register: registry.register)

        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[0], onAnswer: {}, onOverlay: {})

        XCTAssertEqual(registry.live, [HotKeyCombo.answerChoices[0], HotKeyCombo.overlayChoices[0]])
        XCTAssertNil(binder.problem)
    }

    func testTheShortcutsRunTheirActions() {
        let registry = FakeHotKeyRegistry()
        let binder = HotKeyBinder(register: registry.register)
        var ran: [String] = []

        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[0],
                    onAnswer: { ran.append("answer") }, onOverlay: { ran.append("overlay") })
        registry.press(.overlayChoices[0])
        registry.press(.answerChoices[0])

        XCTAssertEqual(ran, ["overlay", "answer"])
    }

    func testAShortcutAnotherAppUsesIsReported() {
        let registry = FakeHotKeyRegistry()
        registry.takenElsewhere = [.answerChoices[0]]
        let binder = HotKeyBinder(register: registry.register)

        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[0], onAnswer: {}, onOverlay: {})

        XCTAssertEqual(binder.problem, "⌘⇧Space is already in use. Pick another shortcut in Settings.")
        XCTAssertEqual(registry.live, [HotKeyCombo.overlayChoices[0]])
    }

    func testPickingAFreeShortcutClearsTheProblem() {
        let registry = FakeHotKeyRegistry()
        registry.takenElsewhere = [.answerChoices[0]]
        let binder = HotKeyBinder(register: registry.register)
        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[0], onAnswer: {}, onOverlay: {})

        binder.bind(answer: .answerChoices[1], overlay: .overlayChoices[0], onAnswer: {}, onOverlay: {})

        XCTAssertNil(binder.problem)
        XCTAssertEqual(Set(registry.live), [HotKeyCombo.answerChoices[1], HotKeyCombo.overlayChoices[0]])
    }

    func testRebindingReleasesTheOldShortcutsFirst() {
        let registry = FakeHotKeyRegistry()
        let binder = HotKeyBinder(register: registry.register)
        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[0], onAnswer: {}, onOverlay: {})

        binder.bind(answer: .answerChoices[0], overlay: .overlayChoices[1], onAnswer: {}, onOverlay: {})

        XCTAssertNil(binder.problem)
        XCTAssertEqual(Set(registry.live), [HotKeyCombo.answerChoices[0], HotKeyCombo.overlayChoices[1]])
    }
}

/// A registration stays live while the binder holds its token, like HotKeyManager.
final class FakeHotKeyRegistry {
    final class Token {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }

    private final class Registration {
        let combo: HotKeyCombo
        weak var token: Token?
        init(combo: HotKeyCombo, token: Token) {
            self.combo = combo
            self.token = token
        }
    }

    var takenElsewhere: Set<HotKeyCombo> = []
    private var registrations: [Registration] = []

    var live: [HotKeyCombo] { registrations.filter { $0.token != nil }.map(\.combo) }

    func register(_ combo: HotKeyCombo, _ action: @escaping () -> Void) throws -> AnyObject {
        if takenElsewhere.contains(combo) || live.contains(combo) { throw HotKeyError.unavailable(combo) }
        let token = Token(action: action)
        registrations.append(Registration(combo: combo, token: token))
        return token
    }

    func press(_ combo: HotKeyCombo) {
        registrations.first { $0.combo == combo && $0.token != nil }?.token?.action()
    }
}
