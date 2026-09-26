import Foundation
import Carbon.HIToolbox

/// A key plus Carbon modifier mask, e.g. `kVK_Space` with `cmdKey | shiftKey`.
struct HotKeyCombo: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String
}

enum HotKeyError: Error, Equatable {
    case unavailable(HotKeyCombo)
}

/// Registers a global (system-wide) hotkey via the Carbon Event Manager.
/// This works without the Accessibility permission, unlike NSEvent global monitors.
/// The action runs on the main thread. Releasing the manager unregisters the hotkey.
final class HotKeyManager {
    static let signature: OSType = 0x4D454154 // 'MEAT'

    let id: UInt32
    private var hotKeyRef: EventHotKeyRef?

    init(combo: HotKeyCombo, action: @escaping () -> Void) throws {
        id = HotKeyDispatch.register(action)
        guard HotKeyDispatch.installHandlerIfNeeded() else { throw HotKeyError.unavailable(combo) }
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else { throw HotKeyError.unavailable(combo) }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        HotKeyDispatch.unregister(id)
    }
}

/// One Carbon handler for every hotkey, routing each press to the action
/// registered under the pressed hotkey's id.
private enum HotKeyDispatch {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var lastID: UInt32 = 0
    private static var handlerRef: EventHandlerRef?

    static func register(_ action: @escaping () -> Void) -> UInt32 {
        lastID += 1
        actions[lastID] = action
        return lastID
    }

    static func unregister(_ id: UInt32) {
        actions[id] = nil
    }

    static func installHandlerIfNeeded() -> Bool {
        guard handlerRef == nil else { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetEventDispatcherTarget(), handle, 1, &eventType, nil, &handlerRef) == noErr
    }

    private static let handle: EventHandlerUPP = { _, event, _ -> OSStatus in
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        guard status == noErr,
              hotKeyID.signature == HotKeyManager.signature,
              let action = actions[hotKeyID.id] else {
            return OSStatus(eventNotHandledErr)
        }
        DispatchQueue.main.async(execute: action)
        return noErr
    }
}
