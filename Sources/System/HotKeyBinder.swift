import Carbon.HIToolbox
import Foundation

extension HotKeyCombo: Identifiable {
    var id: String { label }

    static let answerChoices = [
        HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧Space"),
        HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧A"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥A"),
    ]

    static let overlayChoices = [
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧H"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥H"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey), label: "⌘⇧O"),
        HotKeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥O"),
    ]

    /// The choice saved under `label`, or the first choice when it is unknown.
    static func choice(labeled label: String?, in choices: [HotKeyCombo]) -> HotKeyCombo {
        choices.first { $0.label == label } ?? choices[0]
    }
}

/// Keeps the two global shortcuts registered to match Settings. Registering
/// fails when another app already owns a combination, which is reported so the
/// user can pick another.
@MainActor
final class HotKeyBinder: ObservableObject {
    typealias Register = (HotKeyCombo, @escaping () -> Void) throws -> AnyObject

    @Published private(set) var problem: String?

    private let register: Register
    private var registrations: [AnyObject] = []

    init(register: @escaping Register = { combo, action in try HotKeyManager(combo: combo, action: action) }) {
        self.register = register
    }

    /// Releases the current shortcuts before registering the new ones, so a
    /// shortcut that is kept does not collide with itself.
    func bind(answer: HotKeyCombo, overlay: HotKeyCombo,
              onAnswer: @escaping () -> Void, onOverlay: @escaping () -> Void) {
        registrations = []
        let taken = [(answer, onAnswer), (overlay, onOverlay)].compactMap { combo, action -> String? in
            do {
                registrations.append(try register(combo, action))
                return nil
            } catch {
                return combo.label
            }
        }
        problem = taken.isEmpty
            ? nil
            : "\(taken.joined(separator: " and ")) \(taken.count == 1 ? "is" : "are") already in use. Pick another shortcut in Settings."
    }
}
