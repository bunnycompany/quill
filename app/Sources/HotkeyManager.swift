//
//  HotkeyManager.swift
//  Quill — global hotkey via Carbon's RegisterEventHotKey.
//
//  Why Carbon and not NSEvent.addGlobalMonitorForEvents?
//  - A global NSEvent monitor requires the Accessibility permission and can
//    only OBSERVE keys, not consume them.
//  - RegisterEventHotKey needs no special permission, works while the app is
//    in the background, and swallows the keystroke system-wide. It is old
//    (Carbon-era) but fully supported on macOS 15.
//

import AppKit
import Carbon.HIToolbox

/// Virtual key codes we use (from Carbon's Events.h). Add more as needed.
enum KeyCode {
    static let r: UInt32 = UInt32(kVK_ANSI_R)
}

struct HotkeyModifiers: OptionSet {
    let rawValue: UInt32
    static let command = HotkeyModifiers(rawValue: UInt32(cmdKey))
    static let option  = HotkeyModifiers(rawValue: UInt32(optionKey))
    static let control = HotkeyModifiers(rawValue: UInt32(controlKey))
    static let shift   = HotkeyModifiers(rawValue: UInt32(shiftKey))
}

final class HotkeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let handler: () -> Void

    /// Registers immediately; unregisters in deinit.
    /// - Parameter handler: called on the MAIN thread when the hotkey fires.
    init(keyCode: UInt32, modifiers: HotkeyModifiers, handler: @escaping () -> Void) {
        self.handler = handler

        // 1. Install a Carbon event handler for "hot key pressed" events.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        // C callback: cannot capture Swift context, so we smuggle `self`
        // through userData as an unmanaged pointer. `self` outlives the
        // handler because deinit removes it first.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == manager.hotKeyIDValue {
                DispatchQueue.main.async { manager.handler() }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(),
                            callback,
                            1,
                            &eventType,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandlerRef)

        // 2. Register the key combination itself.
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKeyIDValue)
        RegisterEventHotKey(keyCode,
                            modifiers.rawValue,
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }

    deinit {
        // Teardown in reverse order of setup — forgetting either leaks the
        // registration for the life of the process (the hotkey keeps firing
        // into a dangling pointer => crash).
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    // MARK: - Identity

    /// 'QILL' as a FourCharCode.
    private static let signature: OSType = {
        var result: OSType = 0
        for byte in "QILL".utf8 { result = (result << 8) | OSType(byte) }
        return result
    }()

    private let hotKeyIDValue: UInt32 = 1
}
