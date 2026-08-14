import AppKit
import Carbon.HIToolbox

/// Глобальные горячие клавиши через Carbon RegisterEventHotKey —
/// единственный способ на macOS перехватить сочетание, когда приложение неактивно,
/// не требуя Accessibility-разрешения.
final class HotkeyManager {
    static let shared = HotkeyManager()

    struct Combo {
        var keyCode: UInt32
        var modifiers: UInt32
        static let optionSpace = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        static let optionS = Combo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))
        static let optionV = Combo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey))
        static let optionD = Combo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
        static let optionR = Combo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey))
        static let optionA = Combo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
    }

    private var pressHandlers: [UInt32: () -> Void] = [:]
    private var releaseHandlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    @discardableResult
    func register(_ combo: Combo, handler: @escaping () -> Void) -> Bool {
        register(combo, onPress: handler, onRelease: nil)
    }

    /// С обработчиком отпускания получается «зажал и говори»:
    /// Carbon умеет отдавать оба события для одного и того же сочетания.
    @discardableResult
    func register(_ combo: Combo, onPress: @escaping () -> Void, onRelease: (() -> Void)?) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x564F4342 /* VOCB */), id: id)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[mrdi] не удалось зарегистрировать хоткей (код \(status))")
            return false
        }
        pressHandlers[id] = onPress
        releaseHandlers[id] = onRelease
        refs[id] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32, pressed: Bool) {
        if pressed { pressHandlers[id]?() } else { releaseHandlers[id]?() }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return noErr }
            let id = hkID.id
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { HotkeyManager.shared.fire(id, pressed: pressed) }
            return noErr
        }, 2, &specs, nil, nil)
    }
}
