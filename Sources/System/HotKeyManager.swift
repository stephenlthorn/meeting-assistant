import Foundation
import Carbon.HIToolbox

/// Registers a global (system-wide) hotkey via the Carbon Event Manager.
/// This works without the Accessibility permission, unlike NSEvent global monitors.
/// The callback fires on the main thread.
final class HotKeyManager {
    private let callback: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private static let signature: OSType = 0x4D454154 // 'MEAT'
    private static var counter: UInt32 = 0
    private static func nextID() -> UInt32 { counter += 1; return counter }

    /// - Parameters:
    ///   - keyCode: a virtual key code, e.g. `kVK_Space`.
    ///   - modifiers: Carbon modifier mask, e.g. `UInt32(cmdKey | shiftKey)`.
    init?(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            HotKeyManager.handler,
            1, &eventType, selfPtr, &eventHandler)
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: HotKeyManager.nextID())
        let registerStatus = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private static let handler: EventHandlerUPP = { _, _, userData -> OSStatus in
        guard let userData else { return noErr }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { manager.callback() }
        return noErr
    }
}
