import Carbon
import Foundation

/// 默认快捷键：Option + S
enum DefaultHotKey {
    static let keyCode = UInt32(kVK_ANSI_S)
    static let modifiers = UInt32(optionKey)
    static let display = "⌥S"
}

final class HotKeyManager: @unchecked Sendable {
    static let shared = HotKeyManager()

    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        if installStatus != noErr {
            NSLog("InstallEventHandler failed: \(installStatus)")
            return
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("PSWH"), id: 1)
        let registerStatus = RegisterEventHotKey(
            DefaultHotKey.keyCode,
            DefaultHotKey.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            NSLog("RegisterEventHotKey failed: \(registerStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

private func hotKeyEventHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        HotKeyManager.shared.onPressed?()
    }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
